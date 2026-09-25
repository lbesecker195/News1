defmodule Rnews1Web.Analytics do
  @moduledoc """
  SeriouslySimpleAnalytics' browser tracker, on every page of every host.

  One account (SSA_ACCOUNT_ID) covers the app, the archive and every customer
  site. Traffic is kept apart by *project*, and the project is the host's
  subdomain: `app` for app.rnews1.com, `www` for the archive, and a tenant's
  brandable label for their subdomain — and for their custom domain too,
  because the label is the stable name of that customer while hostnames
  come and go.

  The tracker itself (wa.js) knows only its account, `data-site`. The project
  travels two ways: as `data-project` on the tag, and in the `page_view` ping
  that track.js sends to SSA's ping endpoint, which is where SSA keeps
  projects apart in its reports.

  Form capture is switched off on the tag. A subscribe box or a sign-in form
  holds email addresses, and those are not analytics.

  Unset SSA_ACCOUNT_ID and none of this is emitted: development and tests
  stay out of the numbers, and the content security policy stays closed.
  """
  alias Rnews1.Env
  alias Rnews1.Util.Hosts

  @origin "https://seriouslysimpleanalytics.com"
  @script @origin <> "/wa.js"

  def origin, do: @origin
  def script_url, do: @script

  def account_id, do: Env.ssa_account_id()
  def enabled?, do: is_binary(account_id()) and account_id() != ""

  @doc "Which project a page reports into: the host's subdomain."
  def project(assigns) do
    site = assigns[:site]

    cond do
      assigns[:archive] -> Hosts.archive_label() || "www"
      match?(%{tenant: %{}}, site) -> label(site.tenant)
      match?(%{host: host} when is_binary(host), site) -> host_label(site.host)
      true -> "app"
    end
  end

  defp label(tenant), do: tenant[:subdomain] || tenant["subdomain"] || "site"

  # A host nobody owns still reports somewhere: its label, or the hostname.
  defp host_label(host) do
    case Hosts.classify(host) do
      %{kind: :subdomain, label: label} when is_binary(label) -> label
      _ -> host
    end
  end

  @doc "The tag's attributes for a page, or nil when analytics are off or the page opted out."
  def for_page(assigns) do
    if enabled?() and assigns[:track] != false do
      %{src: @script, site: account_id(), project: project(assigns)}
    end
  end

  @doc "The tag as a string, for the one template outside the layout (the brief page)."
  def tag(assigns) do
    case for_page(assigns) do
      nil ->
        ""

      a ->
        ~s(<script src="#{a.src}" data-site="#{esc(a.site)}" data-project="#{esc(a.project)}" data-forms="false" defer></script>)
    end
  end

  defp esc(value), do: value |> to_string() |> Plug.HTML.html_escape()
end
