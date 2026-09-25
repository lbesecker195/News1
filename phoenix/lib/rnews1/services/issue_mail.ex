defmodule Rnews1.IssueMail do
  @moduledoc """
  The newsletter, rendered once per reader. Inline-styled, table-free HTML with
  a plain-text alternative; email clients are not browsers.
  """
  alias Rnews1.Env
  import Rnews1.Util.HTML, only: [escape: 1, safe_url: 1]

  @ink "#16181d"
  @muted "#5b6270"
  @line "#e4e6eb"
  @accent "#1a4fd6"

  def render_html(%{company: company, date: date} = issue) do
    stories = Map.get(issue, :stories, [])
    ads = Map.get(issue, :ads, %{}) || %{}
    reader = Map.get(issue, :reader)
    [lead | rest] = if stories == [], do: [nil], else: stories

    sections =
      [
        masthead(company, date),
        if(lead, do: lead_story(lead, reader), else: nothing_today()),
        if(ads[:sponsored], do: sponsored(ads[:sponsored]), else: ""),
        if(rest != [], do: blurbs(rest), else: ""),
        Enum.map(ads[:banners] || [], &banner/1),
        footer(Map.get(issue, :unsubscribe_url))
      ] ++ pixels(ads)

    wrap("#{escape(company)} — #{escape(date)}", sections |> List.flatten() |> Enum.reject(&(&1 == "")) |> Enum.join("\n"))
  end

  defp wrap(title, content) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="robots" content="noindex">
    <title>#{title}</title>
    </head>
    <body style="margin:0;padding:0;background:#f6f7f9;">
    <div style="margin:0 auto;padding:28px 20px;max-width:38rem;background:#ffffff;
                font:16px/1.55 -apple-system,'Segoe UI',system-ui,sans-serif;color:#{@ink};">
    #{content}
    </div>
    </body>
    </html>
    """
  end

  defp masthead(company, date) do
    """
    <div style="padding-bottom:16px;border-bottom:2px solid #{@ink};">
      <div style="font-size:1.35rem;font-weight:700;">#{escape(company)}</div>
      <div style="color:#{@muted};font-size:0.85rem;">#{escape(date)}</div>
    </div>
    """
  end

  defp nothing_today, do: ~s(<p style="padding:24px 0;color:#{@muted};">No new coverage matched your topics today.</p>)

  defp lead_story(story, reader) do
    picked =
      if reader && reader[:reason],
        do: ~s(<div style="color:#{@accent};font-size:0.72rem;letter-spacing:0.06em;text-transform:uppercase;padding-bottom:6px;">Picked for you · #{escape(reader[:reason])}</div>),
        else: ""

    """
    <div style="padding:22px 0 8px;">
      #{picked}
      <h1 style="margin:0 0 8px;font-size:1.45rem;line-height:1.25;">#{escape(story.headline)}</h1>
      <p style="margin:0 0 12px;font-size:1.05rem;color:#{@muted};">#{escape(story.standfirst)}</p>
      #{paragraphs(story.body)}
      #{attribution(story)}
    </div>
    """
  end

  defp blurbs(stories) do
    items =
      Enum.map_join(stories, "", fn story ->
        """
        <div style="padding:12px 0;border-top:1px solid #{@line};">
          <h2 style="margin:0 0 4px;font-size:1.05rem;">#{escape(story.headline)}</h2>
          <p style="margin:0 0 6px;color:#{@muted};font-size:0.95rem;">#{escape(story.standfirst)}</p>
          #{attribution(story)}
        </div>
        """
      end)

    """
    <div style="padding-top:8px;border-top:1px solid #{@line};">
      <div style="color:#{@muted};font-size:0.72rem;letter-spacing:0.06em;text-transform:uppercase;padding:14px 0 4px;">Also today</div>
      #{items}
    </div>
    """
  end

  # The sponsored slot is labelled above the headline, in the reader's line of sight.
  defp sponsored(ad) do
    """
    <div style="margin:20px 0;padding:16px 18px;border:1px solid #{@line};border-left:3px solid #{@accent};background:#fbfcfe;">
      <div style="color:#{@muted};font-size:0.7rem;letter-spacing:0.08em;text-transform:uppercase;padding-bottom:8px;">Sponsored</div>
      <h2 style="margin:0 0 6px;font-size:1.1rem;"><a href="#{escape(ad.click_url)}" style="color:#{@ink};text-decoration:none;">#{escape(ad.headline)}</a></h2>
      <p style="margin:0 0 10px;color:#{@muted};">#{escape(ad.body)}</p>
      <a href="#{escape(ad.click_url)}" style="color:#{@accent};font-weight:600;text-decoration:none;">#{escape(ad[:cta] || "Learn more")} →</a>
    </div>
    """
  end

  defp banner(ad) do
    """
    <div style="margin:14px 0;padding:12px 14px;border:1px solid #{@line};">
      <div style="color:#{@muted};font-size:0.65rem;letter-spacing:0.08em;text-transform:uppercase;padding-bottom:4px;">Ad</div>
      <a href="#{escape(ad.click_url)}" style="color:#{@ink};text-decoration:none;font-weight:600;">#{escape(ad.headline)}</a>
      <div style="color:#{@muted};font-size:0.9rem;">#{escape(ad.body)}</div>
    </div>
    """
  end

  defp attribution(story) do
    ~s(<p style="margin:0;color:#{@muted};font-size:0.82rem;">Reported by #{escape(story.source_name)} · <a href="#{escape(safe_url(story.source_url))}" rel="noopener noreferrer" style="color:#{@accent};">Original coverage</a></p>)
  end

  defp paragraphs(body) do
    (body || "")
    |> to_string()
    |> String.split(~r/\n{2,}/)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join("", &~s(<p style="margin:0 0 10px;">#{escape(String.trim(&1))}</p>))
  end

  # The postal address is a statutory requirement, not a courtesy.
  defp footer(unsubscribe_url) do
    unsub = if unsubscribe_url, do: ~s( · <a href="#{escape(unsubscribe_url)}" style="color:#{@muted};">Unsubscribe</a>), else: ""

    """
    <div style="margin-top:22px;padding-top:14px;border-top:1px solid #{@line};color:#{@muted};font-size:0.8rem;">
      <p style="margin:0 0 6px;">Written by Rnews1 from published reporting. Not original journalism — follow the links for the publishers' own coverage.</p>
      <p style="margin:0 0 6px;"><a href="#{escape(Env.app_origin())}" style="color:#{@muted};">Powered by Rnews1</a>#{unsub}</p>
      <p style="margin:0;">Rnews1 &middot; #{escape(Env.business_address())}</p>
    </div>
    """
  end

  defp pixels(ads) do
    [ads[:sponsored] | ads[:banners] || []]
    |> Enum.filter(&(&1 && &1[:pixel_url]))
    |> Enum.map(&~s(<img src="#{escape(&1.pixel_url)}" alt="" width="1" height="1" style="display:block;width:1px;height:1px;border:0;">))
  end

  def render_text(%{company: company, date: date} = issue) do
    stories = Map.get(issue, :stories, [])
    ads = Map.get(issue, :ads, %{}) || %{}
    unsubscribe_url = Map.get(issue, :unsubscribe_url)
    [lead | rest] = if stories == [], do: [nil], else: stories

    lines =
      [company, date, ""] ++
        if(lead,
          do: [String.upcase(lead.headline), lead.standfirst, "", String.replace(lead.body || "", ~r/\n{2,}/, "\n\n"), "", "Reported by #{lead.source_name} — #{safe_url(lead.source_url)}", ""],
          else: ["No new coverage matched your topics today.", ""]
        ) ++
        if(ads[:sponsored], do: ["— SPONSORED —", ads.sponsored.headline, ads.sponsored.body, ads.sponsored.click_url, ""], else: []) ++
        if(rest != [], do: ["ALSO TODAY", "" | Enum.flat_map(rest, &[&1.headline, &1.standfirst, "Reported by #{&1.source_name} — #{safe_url(&1.source_url)}", ""])], else: []) ++
        Enum.flat_map(ads[:banners] || [], &["[Ad] #{&1.headline} — #{&1.body} #{&1.click_url}", ""]) ++
        ["Written by Rnews1 from published reporting. Not original journalism.", "Powered by Rnews1 — #{Env.app_origin()}"] ++
        if(unsubscribe_url, do: ["Unsubscribe: #{unsubscribe_url}"], else: []) ++
        ["", "Rnews1, #{Env.business_address()}"]

    Enum.join(lines, "\n")
  end
end
