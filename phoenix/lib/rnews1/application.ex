defmodule Rnews1.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        Rnews1.Repo,
        {Phoenix.PubSub, name: Rnews1.PubSub},
        Rnews1.Cache,
        Rnews1Web.RateLimit,
        Rnews1.PDF.child_spec_if_available(),
        {Task, &boot/0},
        Rnews1Web.Endpoint
      ] ++ if(Application.get_env(:rnews1, :start_workers, true), do: [Rnews1.Workers.Supervisor], else: [])

    Supervisor.start_link(Enum.reject(children, &is_nil/1), strategy: :one_for_one, name: Rnews1.Supervisor)
  end

  # Once, at boot: the archive's owner as an enterprise tenant, and a word about
  # PayPal being live against a non-https origin. Neither is worth refusing to
  # serve over.
  defp boot do
    if Rnews1.Env.archive_tenant_email() do
      try do
        case Rnews1.House.ensure_house_account() do
          %{owner_email: email, plan: plan} -> Logger.info("Archive account: #{email} (#{plan}, not billed) at #{Rnews1.Env.archive_origin()}")
          _ -> :ok
        end
      rescue
        e -> Logger.error("Could not set up the archive account: #{Exception.message(e)}")
      end
    end

    if Rnews1.PayPal.configured?() do
      if Rnews1.Env.paypal_mode() == "live" and not Rnews1.Env.https?() do
        Logger.warning("PayPal is in LIVE mode but APP_ORIGIN is #{Rnews1.Env.app_origin()}. Subscribing will charge real money against an origin PayPal cannot reach.")
      end
    else
      Logger.warning("PayPal is not configured; subscribing is disabled.")
    end

    if is_nil(Rnews1.PDF.chrome_path()), do: Logger.warning("No Chrome found; PDF rendering is unavailable (set CHROME_EXECUTABLE).")
    :ok
  end

  @impl true
  def config_change(changed, _new, removed) do
    Rnews1Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
