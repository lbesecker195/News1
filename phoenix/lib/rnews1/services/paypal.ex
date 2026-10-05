defmodule Rnews1.PayPal do
  @moduledoc "The PayPal REST client and the subscription operations on top of it."
  alias Rnews1.{Cache, Env, HTTP, PayPalPlans}

  @timeout 30_000
  @expiry_margin 60_000
  @plan_cents 2500
  @brand "Rnews1"

  defmodule Error do
    defexception [:message, status: 0, body: nil, retryable: false]
  end

  def plan_cents, do: @plan_cents
  def plan_usd, do: :erlang.float_to_binary(@plan_cents / 100, decimals: 2)
  def live_statuses, do: ["ACTIVE"]
  def configured?, do: Env.paypal_configured?()

  # ---- auth ------------------------------------------------------------------------

  def access_token do
    case Cache.get(:paypal_token) do
      {:ok, token} -> token
      :miss -> mint_token()
    end
  end

  defp mint_token do
    if not configured?(), do: raise(Error, message: "PayPal is not configured.")

    response =
      request("/v1/oauth2/token",
        method: :post,
        auth: {:basic, "#{Env.paypal_client_id()}:#{Env.paypal_client_secret()}"},
        form: [grant_type: "client_credentials"]
      )

    case response do
      %{status: 200, body: %{"access_token" => token} = body} ->
        ttl = max(0, (body["expires_in"] || 0) * 1000 - @expiry_margin)
        Cache.put(:paypal_token, token, ttl)

      %{status: status, body: body} ->
        raise Error, message: "PayPal authentication failed (#{status})", status: status, body: body
    end
  end

  def reset_token_cache, do: Cache.delete(:paypal_token)

  defp request(path, opts) do
    method = Keyword.get(opts, :method, :get)

    req_opts =
      [url: Env.paypal_base_url() <> path, method: method, receive_timeout: @timeout, retry: false] ++
        Keyword.take(opts, [:auth, :form, :json, :headers])

    case Req.request(HTTP.new(req_opts)) do
      {:ok, %{status: status, body: body}} -> %{status: status, body: if(is_map(body) or is_list(body), do: body, else: %{"raw" => body |> to_string() |> String.slice(0, 500)})}
      {:error, error} -> raise Error, message: "PayPal request did not complete: #{Exception.message(error)}", retryable: true
    end
  end

  @doc "An authenticated call; a 401 drops the cached token and retries once."
  def call(method, path, body \\ nil, retry_auth \\ true) do
    token = access_token()
    opts = [method: method, headers: [{"authorization", "Bearer #{token}"}]] ++ if(is_nil(body), do: [], else: [json: body])
    response = request(path, opts)

    if response.status == 401 and retry_auth do
      reset_token_cache()
      call(method, path, body, false)
    else
      response
    end
  end

  def ok?(%{status: status}), do: status in 200..299

  def error(action, %{status: status, body: body}) do
    detail =
      (is_map(body) && (body["message"] || get_in(body, ["details", Access.at(0), "description"]) || body["error_description"])) || ""

    %Error{
      message: "PayPal #{action} failed (#{status})#{if detail != "", do: ": #{detail}", else: ""}",
      status: status,
      body: body,
      retryable: status == 429 or status >= 500
    }
  end

  # ---- plans and subscriptions -----------------------------------------------------

  def ensure_plan do
    key = "briefing-#{plan_usd()}-month"

    case PayPalPlans.find_by_key(key) do
      nil ->
        product_id = ensure_product()

        response =
          call(:post, "/v1/billing/plans", %{
            product_id: product_id,
            name: "#{@brand} company briefing",
            description: "One company feed, embed and daily briefing for your team.",
            billing_cycles: [
              %{
                frequency: %{interval_unit: "MONTH", interval_count: 1},
                tenure_type: "REGULAR",
                sequence: 1,
                total_cycles: 0,
                pricing_scheme: %{fixed_price: %{currency_code: "USD", value: plan_usd()}}
              }
            ],
            payment_preferences: %{auto_bill_outstanding: true, setup_fee_failure_action: "CANCEL", payment_failure_threshold: 2}
          })

        if not ok?(response), do: raise(error("create plan", response))
        PayPalPlans.create(%{key: key, product_id: product_id, plan_id: response.body["id"], amount_cents: @plan_cents, raw: response.body})

      existing ->
        existing
    end
  end

  defp ensure_product do
    response =
      call(:post, "/v1/catalogs/products", %{
        name: @brand,
        description: "Company news feeds, embeds and daily briefings",
        type: "SERVICE",
        category: "SOFTWARE"
      })

    if not ok?(response), do: raise(error("create product", response))
    response.body["id"]
  end

  def create_subscription(%{email: email, tenant_id: tenant_id, return_url: return_url, cancel_url: cancel_url}) do
    plan = ensure_plan()

    response =
      call(:post, "/v1/billing/subscriptions", %{
        plan_id: plan.plan_id,
        subscriber: %{email_address: email},
        custom_id: "tenant_#{tenant_id}",
        application_context: %{
          brand_name: @brand,
          user_action: "SUBSCRIBE_NOW",
          shipping_preference: "NO_SHIPPING",
          return_url: return_url,
          cancel_url: cancel_url
        }
      })

    if not ok?(response), do: raise(error("create subscription", response))
    response.body
  end

  def get_subscription(id) do
    response = call(:get, "/v1/billing/subscriptions/#{URI.encode(id)}")

    cond do
      response.status == 404 -> nil
      not ok?(response) -> raise error("read subscription", response)
      true -> response.body
    end
  end

  def cancel_subscription(id, reason) do
    response = call(:post, "/v1/billing/subscriptions/#{URI.encode(id)}/cancel", %{reason: String.slice(to_string(reason), 0, 128)})

    cond do
      response.status == 422 -> false
      not ok?(response) -> raise error("cancel subscription", response)
      true -> true
    end
  end

  @doc "Verification is delegated to PayPal; an event that does not verify is dropped."
  def verify_webhook(headers, event) do
    if Env.paypal_webhook_id() == "", do: raise("PAYPAL_WEBHOOK_ID is not set; webhooks cannot be verified.")

    required = ~w(paypal-auth-algo paypal-cert-url paypal-transmission-id paypal-transmission-sig paypal-transmission-time)
    get = fn name -> headers[name] || headers[String.to_atom(name)] end

    if Enum.any?(required, &(get.(&1) in [nil, ""])) do
      false
    else
      response =
        call(:post, "/v1/notifications/verify-webhook-signature", %{
          auth_algo: get.("paypal-auth-algo"),
          cert_url: get.("paypal-cert-url"),
          transmission_id: get.("paypal-transmission-id"),
          transmission_sig: get.("paypal-transmission-sig"),
          transmission_time: get.("paypal-transmission-time"),
          webhook_id: Env.paypal_webhook_id(),
          webhook_event: event
        })

      if not ok?(response), do: raise(error("verify webhook", response))
      response.body["verification_status"] == "SUCCESS"
    end
  end

  def approve_link(resource) do
    (resource["links"] || [])
    |> List.wrap()
    |> Enum.find(&(&1["rel"] in ["approve", "payer-action"]))
    |> case do
      nil -> nil
      link -> link["href"]
    end
  end
end

defmodule Rnews1.Billing do
  @moduledoc "Checkout, cancellation, and the webhook events that change entitlement."
  require Logger
  alias Rnews1.{Companies, Env, HttpError, PayPal, PayPalEvents, Subscribers}

  defp require_paypal! do
    if not PayPal.configured?(), do: raise(HttpError, status: 503, message: "Payments are not configured on this deployment.")
  end

  def create_checkout(tenant_id) do
    require_paypal!()

    Companies.with_billing_lock(tenant_id, fn tenant ->
      if is_nil(tenant) or is_nil(tenant.topic_key) or is_nil(tenant.domain),
        do: raise(HttpError, status: 400, message: "Save your topics and company domain first.")

      existing = if tenant.paypal_subscription_id, do: PayPal.get_subscription(tenant.paypal_subscription_id)

      cond do
        existing && existing["status"] in PayPal.live_statuses() ->
          raise HttpError, status: 409, message: "This company is already subscribed."

        existing && existing["status"] == "APPROVAL_PENDING" && PayPal.approve_link(existing) ->
          PayPal.approve_link(existing)

        true ->
          subscription =
            PayPal.create_subscription(%{
              email: tenant.owner_email,
              tenant_id: tenant.id,
              return_url: "#{Env.app_origin()}/app?checkout=success",
              cancel_url: "#{Env.app_origin()}/app?checkout=canceled"
            })

          link = PayPal.approve_link(subscription) || raise(HttpError, status: 502, message: "PayPal did not return an approval link.")
          Companies.set_subscription(tenant.id, subscription["id"], "approval_pending")
          link
      end
    end)
  end

  def cancel_renewal(tenant_id) do
    require_paypal!()

    Companies.with_billing_lock(tenant_id, fn tenant ->
      if is_nil(tenant) or is_nil(tenant.paypal_subscription_id), do: raise(HttpError, status: 400, message: "No subscription to cancel.")
      PayPal.cancel_subscription(tenant.paypal_subscription_id, "Cancelled from the Rnews1 dashboard")
      Companies.set_billing_status(tenant.id, tenant.paypal_subscription_id, "cancelled")
      %{message: "Renewals stopped. Your feed stays up until the paid period ends."}
    end)
  end

  @subscription_events %{
    "BILLING.SUBSCRIPTION.ACTIVATED" => "active",
    "BILLING.SUBSCRIPTION.RE-ACTIVATED" => "active",
    "BILLING.SUBSCRIPTION.UPDATED" => nil,
    "BILLING.SUBSCRIPTION.CANCELLED" => "cancelled",
    "BILLING.SUBSCRIPTION.SUSPENDED" => "suspended",
    "BILLING.SUBSCRIPTION.EXPIRED" => "expired",
    "BILLING.SUBSCRIPTION.PAYMENT.FAILED" => "past_due"
  }

  def process_event(%{"event_type" => type, "resource" => resource} = event) when is_binary(type) and is_map(resource) do
    fresh = PayPalEvents.record(%{id: to_string(event["id"]), kind: type, resource_id: resource["id"] && to_string(resource["id"])})

    cond do
      not fresh ->
        :ok

      type == "PAYMENT.SALE.COMPLETED" ->
        subscription_id = resource["billing_agreement_id"]

        if subscription_id && Companies.sync_subscription(%{subscription_id: subscription_id, status: "active"}) do
          enrol_owner_for(subscription_id)
        end

        :ok

      not Map.has_key?(@subscription_events, type) ->
        :ok

      true ->
        subscription_id = resource["id"]

        status =
          Map.get(@subscription_events, type) ||
            (subscription_id && (PayPal.get_subscription(subscription_id) || %{})["status"] |> then(&(&1 && String.downcase(&1))))

        cond do
          is_nil(subscription_id) or is_nil(status) ->
            :ok

          not Companies.sync_subscription(%{subscription_id: subscription_id, status: status}) ->
            Logger.error("PayPal subscription #{subscription_id} matched no tenant. Ignored.")
            :ok

          status == "active" ->
            enrol_owner_for(subscription_id)
            :ok

          true ->
            :ok
        end
    end
  end

  def process_event(_), do: :ok

  defp enrol_owner_for(subscription_id) do
    Companies.with_owner_of_subscription(subscription_id, fn tenant -> Subscribers.enrol_owner(tenant.id, tenant.owner_email) end)
  rescue
    e -> Logger.error("Could not enrol owner for subscription #{subscription_id}: #{Exception.message(e)}")
  end
end
