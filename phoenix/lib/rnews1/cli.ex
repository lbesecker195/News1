defmodule Rnews1.CLI do
  @moduledoc """
  The operations the Node app exposed as npm scripts. Callable from mix tasks
  in development and from `bin/rnews1 eval 'Rnews1.CLI.login(["me@x"])'` in a
  release.
  """
  alias Rnews1.{Accounts, Admins, Clicks, Editorial, Env, Reports, Sites, Subscribers, Worker}
  alias Rnews1.Util.{Ids, Languages}

  def create_admin([email, password | rest]) do
    email = String.downcase(String.trim(email))
    comp = "--comp" in rest
    admin = Admins.upsert(%{email: email, password: password})
    IO.puts("#{if admin.created, do: "Created", else: "Updated"} admin #{admin.email}")

    if comp do
      tenant_id = Rnews1.DB.transaction(fn -> Sites.ensure_tenant(%{email: email, columns: %{billing_status: "active", comped_reason: "platform staff account"}}) end)
      Rnews1.DB.execute("UPDATE tenants SET billing_status = 'active', comped_reason = 'platform staff account' WHERE id = $1", [tenant_id])
      Subscribers.enrol_owner(tenant_id, email)
      IO.puts("Comped tenant for #{email} — active, no subscription needed.")
    end
  end

  def create_admin(_), do: IO.puts("Usage: mix rnews1.admin <email> <password> [--comp]")

  def login(args) do
    case Enum.find(args, &String.contains?(&1, "@")) do
      nil ->
        rows = Rnews1.DB.all("SELECT o.to_email, o.payload->>'url' AS url, o.status, o.expires_at < now() AS expired FROM outbox o WHERE o.kind = 'login' ORDER BY o.created_at DESC LIMIT 5")

        if rows == [] do
          IO.puts("\nNo sign-in links queued. Request one at #{Env.app_origin()}/login, or run: mix rnews1.login you@example.com\n")
        else
          IO.puts("\nMost recent sign-in links:\n")
          for row <- rows, do: IO.puts("  #{row.to_email}  ·  #{if row.expired, do: "expired", else: row.status}\n  #{row.url}\n")
        end

      email ->
        secret = Ids.token()
        email = email |> String.trim() |> String.downcase()
        Accounts.create_login(%{email: email, token_hash: Ids.hash(secret), url: "#{Env.app_origin()}/login/#{secret}"})
        IO.puts("\nIssued for #{email}:\n\n  #{Env.app_origin()}/login/#{secret}\n")
    end
  end

  def content(args) do
    Env.require!([:openai_api_key, :treg_token])
    dry_run = "--dry-run" in args
    only = flag(args, "--category")
    categories = if only, do: [Editorial.match_category(only)] |> Enum.reject(&is_nil/1), else: Editorial.categories()
    if only && categories == [], do: raise("Unknown section \"#{only}\". One of: #{Enum.join(Editorial.categories(), ", ")}")
    concurrency = (flag(args, "--concurrency") || to_string(Editorial.translation_concurrency())) |> String.to_integer()
    languages = case flag(args, "--languages"), do: (nil -> Editorial.translation_languages(); v -> v |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")))

    IO.puts("#{if dry_run, do: "Dry run: ", else: ""}#{length(categories)} section(s), #{length(languages) + 1} language(s) each, #{concurrency} translation(s) at a time\n")

    results =
      Enum.map(categories, fn category ->
        started = System.monotonic_time(:second)
        result = Editorial.write_for_category(category, languages: languages, concurrency: concurrency, dry_run: dry_run)
        result = Map.put(result, :seconds, System.monotonic_time(:second) - started)
        IO.puts("  " <> line(result))
        result
      end)

    published = Enum.filter(results, &(&1.status in ["published", "would_publish"]))
    IO.puts("\n#{length(published)}/#{length(results)} section(s) #{if dry_run, do: "ready to publish", else: "published"}")

    for r <- results, r.status not in ["published", "would_publish"] do
      IO.puts("  #{r.category}: #{r.status}#{if r[:attempts], do: " after #{r.attempts} publisher(s)", else: ""}")
      if r[:detail], do: IO.puts("      #{r.detail}")
    end
  end

  defp line(%{status: status, category: category} = r) when status in ["published", "would_publish"] do
    "#{String.pad_trailing(category, 14)}#{r.languages |> length() |> to_string() |> String.pad_leading(2)} langs  #{r[:seconds] |> to_string() |> String.pad_leading(3)}s  verbatim:#{r[:verbatim_run] |> to_string() |> String.pad_leading(2)}  #{String.slice(r.headline, 0, 40)}"
  end

  defp line(r), do: "#{String.pad_trailing(r.category, 14)}#{r.status}"

  def translate(args) do
    Env.require!([:openai_api_key])
    dry_run = "--dry-run" in args
    languages = case flag(args, "--languages"), do: (nil -> Languages.codes(); v -> String.split(v, ","))
    limit = (flag(args, "--limit") || "25") |> String.to_integer()
    results = Editorial.backfill_translations(languages: languages, limit: limit, dry_run: dry_run)

    if results == [] do
      IO.puts("\nNothing missing: every article is in all #{length(languages)} languages.\n")
    else
      IO.puts("\n#{if dry_run, do: "Would translate", else: "Translated"} #{length(results)} article(s):\n")

      for r <- results do
        gaps = r[:missing] || (r[:added] || []) ++ (r[:failed] || [])
        IO.puts("  #{String.pad_trailing(to_string(r.status), 16)}#{gaps |> length() |> to_string() |> String.pad_leading(2)} locale(s)  #{String.slice(r.key || "", 0, 44)}")
        if r[:failed] not in [nil, []], do: IO.puts("      failed: #{Enum.join(r.failed, ", ")}")
      end
    end
  end

  def custom_report(args) do
    Env.require!([:openai_api_key])
    email = Enum.find(args, &(String.contains?(&1, "@") and not String.starts_with?(&1, "--")))

    contact =
      if email do
        Rnews1.DB.one("SELECT id, name, title, company, industry FROM contacts WHERE email = $1", [String.downcase(String.trim(email))]) ||
          raise("No contact with the address #{email}. Import them first, or pass --title and --company instead.")
      else
        %{name: flag(args, "--name"), title: flag(args, "--title"), company: flag(args, "--company"), industry: flag(args, "--industry")}
      end

    if is_nil(email) and is_nil(contact[:title]) and is_nil(contact[:company]),
      do: raise("Give an email address, or --title and --company.")

    report = Reports.build_custom_report(contact, language: flag(args, "--language") || "en", section_count: String.to_integer(flag(args, "--sections") || "4"), per_section: String.to_integer(flag(args, "--per-section") || "2"))
    IO.puts("\nReport for #{[contact[:name], contact[:title], contact[:company]] |> Enum.reject(&is_nil/1) |> Enum.join(", ")}\n")
    for s <- report.sections, do: IO.puts("  #{String.pad_trailing(s.name, 14)}#{s.why}")
    IO.puts("\n  #{report.stories} stor#{if report.stories == 1, do: "y", else: "ies"}#{if report.personalised, do: "", else: "  (sections not ranked — defaults used)"}")
    IO.puts("\n  #{Env.app_origin()}/brief/#{report.id}\n")
  end

  def pdf([id | rest]) do
    record = Rnews1.Briefs.find_unexpired(id) || raise("No unexpired brief with id #{id}.")
    %{html: html, content: content, model: model} = Rnews1.BriefPage.render(record)
    out = flag(rest, "--out")

    file =
      if out do
        File.write!(out, Rnews1.PDF.html_to_pdf(html, content.print))
        out
      else
        f = Rnews1.PDF.write_brief_pdf(id, html, content.print)
        Rnews1.Briefs.mark_pdf_written(id)
        f
      end

    IO.puts("#{length(model.stories)} stor#{if length(model.stories) == 1, do: "y", else: "ies"}, #{content.print.pageSize} → #{file}")
  end

  def pdf(_), do: IO.puts("Usage: mix rnews1.pdf <brief-id> [--out file.pdf]")

  def clicks(args) do
    days = String.to_integer(flag(args, "--days") || "30")
    rows = Clicks.top_targets(host: flag(args, "--host"), days: days, limit: String.to_integer(flag(args, "--limit") || "30"))

    if rows == [] do
      IO.puts("No clicks recorded in the last #{days} days.")
    else
      IO.puts("\nTop clicks, last #{days} days\n")
      IO.puts("#{String.pad_leading("CLICKS", 7)}  #{String.pad_trailing("KIND", 7)}#{String.pad_trailing("PAGE", 38)}WHAT")

      for row <- rows do
        IO.puts("#{row.clicks |> to_string() |> String.pad_leading(7)}  #{String.pad_trailing(row.kind, 7)}#{row.path |> trim(36) |> String.pad_trailing(38)}#{row.label || row.target || ""}#{if row.external, do: "  (offsite)", else: ""}")
      end
    end
  end

  def plan([date | _]), do: IO.inspect(Worker.plan_campaign(date))
  def plan(_), do: IO.puts("Usage: mix rnews1.plan YYYY-MM-DD")

  def once(_args) do
    IO.inspect(Worker.refresh_one_topic(), label: "content")
    IO.inspect(Worker.schedule_digests(), label: "scheduler")
    IO.inspect(Worker.deliver_one(), label: "delivery")
    IO.inspect(Worker.maintenance(), label: "maintenance")
  end

  defp trim(value, width) do
    text = to_string(value || "")
    if String.length(text) > width, do: String.slice(text, 0, width - 1) <> "…", else: text
  end

  def flag(args, name) do
    case Enum.find_index(args, &(&1 == name)) do
      nil -> nil
      index -> Enum.at(args, index + 1)
    end
  end
end
