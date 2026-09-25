defmodule Rnews1.Worker do
  @moduledoc """
  The work the loops do, as plain functions: refresh a topic, schedule the
  day's digests, deliver one message, run maintenance. Each is callable on
  its own from a task or a test.
  """
  require Logger
  alias Rnews1.{Ads, AdSelection, BriefPage, Briefs, Campaigns, Clicks, DB, Digests, Domains, Env, IssueMail, Mailer, News, Outbox, PayPalEvents, PDF, Stories, StoryPipeline, Topics}
  import Rnews1.Util.HTML, only: [escape: 1]

  # ---- content -------------------------------------------------------------------------

  def refresh_one_topic do
    case Topics.claim_stale_topic() do
      nil ->
        nil

      topic ->
        try do
          fresh = News.fetch_topic_items(query: topic.query, language: topic.language)
          merged = News.merge_items(topic.items, fresh)
          Topics.save_items(topic.key, merged)
          %{key: topic.key, fetched: length(fresh), total: length(merged)}
        rescue
          e ->
            Logger.error("Topic #{topic.key} refresh failed: #{Exception.message(e)}")
            Topics.record_failure(topic.key, Exception.message(e))
            %{key: topic.key, error: Exception.message(e)}
        end
    end
  end

  # ---- scheduling ----------------------------------------------------------------------

  def schedule_digests(now \\ DateTime.utc_now()) do
    if now.hour < Env.digest_hour() do
      nil
    else
      date = now |> DateTime.to_date() |> Date.to_iso8601()

      scheduled =
        Digests.with_tenant_due_for_digest(date, fn tenant ->
          for recipient <- tenant.recipients do
            Outbox.enqueue(%{
              tenant_id: tenant.id,
              contact_id: recipient.contact_id,
              to_email: recipient.email,
              kind: "digest",
              payload: %{company: tenant.name, topicKey: tenant.topic_key, topicQuery: tenant.topic_query, unsubscribeUrl: "#{Env.app_origin()}/u/#{recipient.unsub_token}", date: date},
              expires_at: DateTime.add(DateTime.utc_now(), 36 * 3600, :second),
              dedupe_key: "digest:#{tenant.id}:#{recipient.contact_id}:#{date}"
            })
          end

          %{tenant_id: tenant.id, topic_key: tenant.topic_key, topic_query: tenant.topic_query, language: tenant.language, company: tenant.name || "Your company", date: date, recipients: length(tenant.recipients)}
        end)

      case scheduled do
        nil ->
          nil

        scheduled ->
          stories =
            try do
              StoryPipeline.build_issue(%{topic_key: scheduled.topic_key, query: scheduled.topic_query, language: scheduled.language, issue_date: scheduled.date})
            rescue
              e ->
                Logger.error("Issue for #{scheduled.topic_key} failed: #{Exception.message(e)}")
                []
            end

          brief_id =
            try do
              html = IssueMail.render_html(%{company: scheduled.company, date: scheduled.date, stories: stories})
              id = Briefs.create(%{tenant_id: scheduled.tenant_id, html: html, story_ids: Enum.map(stories, & &1.id), issue_date: scheduled.date})

              if PDF.available?() do
                page = BriefPage.render(Briefs.find_unexpired(id))
                PDF.write_brief_pdf(id, page.html, page.content.print)
                Briefs.mark_pdf_written(id)
              end

              id
            rescue
              e ->
                Logger.error("Brief for #{scheduled.tenant_id} failed: #{Exception.message(e)}")
                nil
            end

          scheduled |> Map.put(:stories, length(stories)) |> Map.put(:brief_id, brief_id)
      end
    end
  end

  def plan_campaign(date, opts \\ []) do
    if not Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, to_string(date)), do: raise("Usage: mix rnews1.plan YYYY-MM-DD")
    {:ok, run_after, _} = DateTime.from_iso8601("#{date}T14:00:00Z")
    contacts = Digests.list_campaign_contacts(Keyword.get(opts, :limit, 500))

    queued =
      Enum.count(contacts, fn contact ->
        Outbox.enqueue(%{
          contact_id: contact.id,
          to_email: contact.email,
          kind: "campaign",
          payload: %{name: contact.name, company: contact.company, unsubscribeUrl: "#{Env.app_origin()}/u/#{contact.unsub_token}"},
          run_after: run_after,
          expires_at: DateTime.add(run_after, 7 * 86_400, :second),
          dedupe_key: "campaign:#{contact.id}:#{date}"
        }) != nil
      end)

    %{date: date, eligible: length(contacts), queued: queued}
  end

  # ---- delivery -----------------------------------------------------------------------

  defmodule Unbuildable do
    defexception [:message]
  end

  def build_message(job) do
    payload = job.payload || %{}

    case job.kind do
      "login" ->
        %{
          subject: "Your Rnews1 sign-in link",
          text: Enum.join(["Use this link to sign in to Rnews1:", payload["url"], "", "The link expires in 20 minutes and can only be used once.", "If you did not request it, you can ignore this email."], "\n"),
          html: paragraphs(["Use this link to sign in to Rnews1:", link(payload["url"], "Sign in to Rnews1"), "The link expires in 20 minutes and can only be used once.", "If you did not request it, you can ignore this email."]),
          tag: "login"
        }

      "confirmation" ->
        company = payload["company"] || "company"

        %{
          subject: "Confirm your #{company} briefing",
          text: Enum.join(["#{payload["company"] || "A company"} has invited you to receive a", "daily Rnews1 news briefing.", "", "Confirm here:", payload["url"], "", "If you did not expect this, ignore this email and nothing is sent."], "\n"),
          html: paragraphs(["#{escape(payload["company"] || "A company")} has invited you to receive a daily Rnews1 news briefing.", link(payload["url"], "Confirm my subscription"), "If you did not expect this, ignore this email and nothing is sent."]),
          tag: "confirmation"
        }

      "digest" ->
        build_issue_message(job, payload)

      "campaign" ->
        greeting = if payload["name"], do: "Hi #{payload["name"]},", else: "Hello,"

        %{
          subject: "One useful daily briefing for your team",
          text: Enum.join([greeting, "", "Rnews1 turns the topics your company follows into a shared news", "feed, a website embed, and a daily email for your team.", "$25 a month, unlimited recipients, cancel online.", "", Env.app_origin(), "", "Unsubscribe: #{payload["unsubscribeUrl"]}", "", "Rnews1, #{Env.business_address()}"], "\n"),
          html: paragraphs([escape(greeting), "Rnews1 turns the topics your company follows into a shared news feed, a website embed, and a daily email for your team. $25 a month, unlimited recipients, cancel online.", link(Env.app_origin(), "See how it works"), link(payload["unsubscribeUrl"], "Unsubscribe"), escape("Rnews1 · #{Env.business_address()}")]),
          tag: "campaign",
          headers: unsubscribe_headers(payload["unsubscribeUrl"])
        }

      other ->
        raise Unbuildable, message: "Unknown outbox kind: #{other}"
    end
  end

  # One reader's issue, assembled now: the model picks the lead, then the ad slots are filled.
  defp build_issue_message(job, payload) do
    company = payload["company"] || "Your company"
    date = payload["date"]
    topic_key = payload["topicKey"]
    day_stories = if topic_key, do: Stories.for_issue(topic_key, date), else: []

    contact = job.contact_id && DB.one("SELECT id, name, title, company, industry FROM contacts WHERE id=$1", [job.contact_id])

    {ordered, reason} =
      if contact && day_stories != [] do
        ordered = StoryPipeline.pick_for_contact(%{contact: contact, topic_key: topic_key, issue_date: date, pool: day_stories})
        picks = Stories.find_picks(contact.id, topic_key, date)
        {ordered, if(picks && picks.personalised, do: picks.reason)}
      else
        {day_stories, nil}
      end

    placed = DB.transaction(fn -> AdSelection.select_ads(%{contact: contact, tenant_id: job.tenant_id, issue_date: date, topic_terms: topic_terms(payload)}) end)

    issue = %{company: company, date: date, stories: ordered, ads: placed, unsubscribe_url: payload["unsubscribeUrl"], reader: if(reason, do: %{reason: reason})}

    %{
      subject: if(ordered != [], do: hd(ordered).headline, else: "#{company} — #{date}"),
      text: IssueMail.render_text(issue),
      html: IssueMail.render_html(issue),
      tag: "digest",
      headers: unsubscribe_headers(payload["unsubscribeUrl"])
    }
  end

  defp topic_terms(payload) do
    ~r/"([^"]+)"/ |> Regex.scan(to_string(payload["topicQuery"] || "")) |> Enum.map(fn [_, term] -> term end)
  end

  defp unsubscribe_headers(nil), do: %{}
  defp unsubscribe_headers(url), do: %{"List-Unsubscribe" => "<#{url}>", "List-Unsubscribe-Post" => "List-Unsubscribe=One-Click"}

  defp link(url, label), do: ~s(<a href="#{escape(url)}">#{escape(label)}</a>)

  defp paragraphs(lines) do
    ~s(<!doctype html>\n<html lang="en"><body style="font:16px/1.55 -apple-system,system-ui,sans-serif;color:#16181d;max-width:34rem;margin:0 auto;padding:24px">\n) <>
      Enum.map_join(lines, "\n", &"<p>#{&1}</p>") <> "\n</body></html>"
  end

  def deliver_one do
    case Outbox.claim_job() do
      nil -> nil
      job -> deliver(job)
    end
  end

  defp deliver(job) do
    paused = if job.kind == "campaign", do: Campaigns.assert_healthy()

    cond do
      paused ->
        Logger.warning("Campaign paused: #{paused}")
        Outbox.defer_job(job.id, 360, paused)
        %{id: job.id, deferred: true}

      job.contact_id && job.kind != "login" && suppressed?(job.contact_id) ->
        Outbox.mark_suppressed(job.id, "recipient suppressed")
        %{id: job.id, suppressed: true}

      true ->
        case build(job) do
          {:error, %Unbuildable{message: message}} ->
            Outbox.mark_failed(job.id, message)
            %{id: job.id, failed: true}

          {:error, e} when job.attempts < 5 ->
            Outbox.retry_later(job.id, job.attempts, Exception.message(e))
            %{id: job.id, retrying: true}

          {:error, e} ->
            Outbox.mark_failed(job.id, Exception.message(e))
            %{id: job.id, failed: true}

          {:ok, message} ->
            send_job(job, message)
        end
    end
  end

  defp suppressed?(contact_id) do
    case DB.one("SELECT opted_out_at, bounced_at FROM contacts WHERE id=$1", [contact_id]) do
      nil -> true
      contact -> not is_nil(contact.opted_out_at) or not is_nil(contact.bounced_at)
    end
  end

  defp build(job) do
    {:ok, build_message(job)}
  rescue
    e -> {:error, e}
  end

  defp send_job(job, message) do
    case Mailer.send_email(Map.merge(message, %{to: job.to_email, job_id: job.id})) do
      {:ok, message_id} ->
        Outbox.mark_accepted(job.id, message_id)
        %{id: job.id, accepted: true}
    end
  rescue
    e in Mailer.Error ->
      cond do
        e.unknown ->
          Outbox.mark_unknown(job.id, e.message)
          %{id: job.id, unknown: true}

        e.retryable and job.attempts < Outbox.max_attempts() ->
          Outbox.retry_later(job.id, job.attempts, e.message)
          %{id: job.id, retrying: true}

        true ->
          Outbox.mark_failed(job.id, e.message)
          %{id: job.id, failed: true}
      end
  end

  # ---- maintenance ------------------------------------------------------------------

  def maintenance do
    requeued = Outbox.requeue_stuck()
    exhausted = Outbox.fail_exhausted()
    expired = Outbox.expire_stale()
    Outbox.prune_auth()
    Outbox.prune()
    Outbox.prune_events()
    Clicks.prune()
    PayPalEvents.prune()
    Topics.park_unused()
    campaigns = Ads.complete_finished_campaigns()

    domains =
      try do
        Domains.recheck_domains()
      rescue
        e ->
          Logger.error("Domain re-check failed: #{Exception.message(e)}")
          %{checked: 0, failing: 0, dropped: 0}
      end

    removed = Briefs.delete_expired()

    for brief <- removed, brief.has_pdf do
      try do
        PDF.delete_brief_pdf(brief.id)
      rescue
        e -> Logger.error("Could not remove PDF #{brief.id}: #{Exception.message(e)}")
      end
    end

    %{requeued: requeued, exhausted: exhausted, expired: expired, campaigns: campaigns, briefs: length(removed), domains: domains.checked, domains_failing: domains.failing}
  end
end
