defmodule Rnews1Web.CompanyController do
  use Rnews1Web, :controller
  alias Rnews1.{Accounts, AI, Companies, Publications, Sites, Subscribers}
  alias Rnews1.Util.{Hosts, Ids}
  alias Rnews1Web.DomainController
  import Rnews1Web.Validation

  @feed_items 8

  defp stakeholders(count, billing_status) do
    required = Subscribers.required_stakeholders()
    %{count: count, required: required, remaining: max(0, required - count), published: count >= required and Companies.billing_active?(billing_status)}
  end

  def me(conn, _) do
    tenant = conn.assigns.tenant
    count = Subscribers.count_for_tenant(tenant.id)
    site = DomainController.site_summary(tenant)
    password = Accounts.has_password(tenant.id)

    conn
    |> no_store()
    |> json(%{
      tenant: %{
        plan: site.entitlements.plan,
        comped: site.entitlements.comped,
        name: tenant.name,
        domain: tenant.domain,
        industry: tenant.industry,
        keywords: tenant.keywords,
        language: tenant.language,
        billing_status: tenant.billing_status
      },
      # Every site this account can switch between: the briefing fused to the
      # tenants row, then each news site it owns. The briefing is always first
      # because it is the one that cannot be removed.
      sites:
        [
          %{
            id: "briefing",
            kind: "briefing",
            label: tenant.name || tenant.subdomain,
            origin: site.origin,
            address: site.origin
          }
        ] ++
          Enum.map(Publications.list_for_tenant(tenant.id), fn publication ->
            %{
              id: publication.slug,
              kind: "publication",
              label: publication.name,
              origin: Hosts.publication_origin(publication),
              address: Hosts.publication_origin(publication),
              languages: publication.languages,
              sections: Publications.section_names(publication.id)
            }
          end),
      password: %{set: password.set, setAt: password.password_set_at},
      subscribers: Subscribers.list_for_tenant(tenant.id),
      stakeholders: stakeholders(count, tenant.billing_status),
      site: site,
      rss: "#{site.origin}/feed.xml",
      embed: "#{site.origin}/embed"
    })
  end

  def save(conn, _) do
    input = company!(body(conn))

    domain =
      case Hosts.company_domain(input.domain) do
        {:ok, domain} -> domain
        {:error, _} -> fail!(400, "Enter a valid company domain.")
      end

    input = %{input | domain: domain}

    terms =
      [input.industry | input.keywords]
      |> Enum.map(&(&1 |> String.replace(~r/["\\]/, "") |> String.trim()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if terms == [], do: fail!(400, "Add an industry or at least one keyword.")

    query = Enum.map_join(terms, " OR ", &"\"#{&1}\"")
    topic = %{query: query, key: Ids.hash("#{input.language}:#{query}")}

    Companies.save_settings(conn.assigns.tenant.id, input, topic)

    # A freemail sign-up has a placeholder subdomain; the company name replaces it.
    if Hosts.placeholder_label?(conn.assigns.tenant.subdomain), do: Sites.adopt_name_label(conn.assigns.tenant.id, input.name)

    json(conn, %{message: "Saved. RNews1 is finding coverage for your topics; your preview will appear shortly."})
  end

  def suggest(conn, _) do
    input = suggestion_input!(body(conn))

    output =
      AI.json(
        """
        Suggest a news industry label and exactly 2 industry keywords.
        Do not claim you visited the website.
        Domain and company name may be ambiguous.
        These are suggestions for the user to confirm.
        Return {"industry":"...","keywords":["..."]}.
        """,
        input
      )

    industry = output["industry"]
    keywords = output["keywords"] |> List.wrap() |> Enum.map(&(&1 |> to_string() |> String.trim())) |> Enum.reject(&(&1 == ""))

    if not is_binary(industry) or String.trim(industry) == "" or length(keywords) < keyword_count() do
      fail!(502, "Suggestions are unavailable right now. Enter your topics manually.")
    end

    json(conn, %{industry: String.slice(String.trim(industry), 0, 100), keywords: Enum.take(keywords, keyword_count())})
  end

  def preview(conn, _) do
    data = Companies.find_preview(conn.assigns.tenant.topic_key)
    conn |> no_store() |> json(%{items: Enum.take(data.items, @feed_items), refreshed_at: data.refreshed_at})
  end
end
