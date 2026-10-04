defmodule Rnews1.EditionMail do
  @moduledoc """
  A publication's newsletter edition: real news first, then one quiet card from
  RNews1. The same template serves every publication — the archive, FashionShowOn
  and any added later — taking its name, tagline, host and stories from the row.

  Inline-styled, table-free HTML with a plain-text alternative, like IssueMail:
  email clients are not browsers, and nothing here may depend on a stylesheet.

  The card is labelled by where it comes from ("From RNews1"), not as an
  advertisement: RNews1 is the publisher promoting its own service. Once an
  affiliate sends it, the disclosure row below the call to action is what the
  FTC's endorsement rules require, and it renders from `referral` alone so no
  affiliate can word it away.
  """
  import Rnews1.Util.HTML, only: [escape: 1, safe_url: 1]

  @ink "#16181d"
  @body "#3a3f4a"
  @muted "#5b6270"
  @line "#e4e6eb"
  @ground "#f6f7f9"
  @accent "#1a4fd6"
  @serif "'Iowan Old Style','Palatino Linotype',Palatino,Georgia,serif"
  @sans "-apple-system,'Segoe UI',system-ui,sans-serif"

  def render_html(edition) do
    sections = [
      preheader(edition),
      browser_link(edition),
      masthead(edition),
      index(edition),
      lead(edition.lead),
      promo(edition),
      also_today(edition.also),
      highlight(Map.get(edition, :highlight)),
      footer(edition)
    ]

    wrap(edition.publication.name, sections |> Enum.reject(&(&1 == "")) |> Enum.join("\n"))
  end

  def render_text(edition) do
    pub = edition.publication
    lead = edition.lead

    [
      "#{pub.name}#{if pub.tagline, do: " — #{pub.tagline}", else: ""}",
      edition.date,
      if(edition.web_url, do: "View in a browser: #{edition.web_url}", else: nil),
      "",
      if(lead,
        do: [
          String.upcase(lead.section),
          lead.headline,
          "",
          lead.standfirst,
          "",
          lead.paragraph,
          "",
          "Read the full story: #{lead.url}",
          ""
        ],
        else: nil
      ),
      "FROM RNEWS1#{affiliate_suffix(edition)}",
      "Get a briefing like this for your company",
      promo_body(),
      "",
      "Start your company's briefing: #{cta_url(edition)}",
      "$25/month · Preview free, no card",
      disclosure_text(edition),
      "",
      "ALSO TODAY",
      Enum.map(edition.also, fn s ->
        ["", "#{String.upcase(s.section)}: #{s.headline}", s.standfirst, s.url]
      end),
      highlight_text(Map.get(edition, :highlight)),
      "",
      footer_reason_text(edition),
      if(edition.unsubscribe_url,
        do: "Unsubscribe — one click, no sign-in: #{edition.unsubscribe_url}",
        else: nil
      ),
      "Every headline links to the full story, written by RNews1 from published reporting with each publisher named.",
      "RNews1 · #{edition.address}"
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # ---- the parts ---------------------------------------------------------------

  defp wrap(title, content) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="color-scheme" content="light">
    <meta name="supported-color-schemes" content="light">
    <meta name="x-apple-disable-message-reformatting">
    <title>#{escape(title)}</title>
    </head>
    <body style="margin:0;padding:0;background:#{@ground};-webkit-text-size-adjust:100%;">
    <div style="margin:0 auto;max-width:600px;background:#ffffff;padding:32px 28px 28px;box-sizing:border-box;font:16px/1.55 #{@sans};color:#{@ink};">
    #{content}
    </div>
    </body>
    </html>
    """
  end

  # Shown in the inbox beside the subject. News only: the pitch never reaches the
  # inbox view, so the open is earned by the reporting.
  defp preheader(%{also: also}) do
    text = also |> Enum.take(3) |> Enum.map_join(", ", & &1.headline)

    if text == "" do
      ""
    else
      ~s(<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;font-size:1px;color:#{@ground};">Also: #{escape(text)}</div>)
    end
  end

  defp browser_link(%{web_url: nil}), do: ""
  defp browser_link(%{unsubscribe_url: nil}), do: ""

  defp browser_link(%{web_url: url}) do
    ~s(<div style="text-align:right;margin:-12px 0 12px;font-size:12px;"><a href="#{safe_url(url)}" style="color:#{@muted};">View in a browser</a></div>)
  end

  defp masthead(%{publication: pub, date: date}) do
    line = Enum.reject([pub.tagline, date], &(&1 in [nil, ""])) |> Enum.map_join(" · ", &escape/1)

    """
    <div style="padding-bottom:16px;border-bottom:2px solid #{@ink};">
      <div style="font-family:#{@serif};font-size:30px;line-height:34px;font-weight:700;letter-spacing:-0.01em;">#{escape(pub.name)}</div>
      <div style="margin-top:4px;font-size:13px;line-height:18px;color:#{@muted};">#{line}</div>
    </div>
    """
  end

  defp index(%{lead: lead, also: also}) do
    sections = [lead | also] |> Enum.reject(&is_nil/1) |> Enum.map(& &1.section) |> Enum.uniq()

    if sections == [] do
      ""
    else
      ~s(<p style="margin:14px 0 0;font-size:13px;line-height:19px;color:#{@muted};">In this issue: #{Enum.map_join(sections, " · ", &escape/1)}</p>)
    end
  end

  defp lead(nil) do
    ~s(<p style="margin:26px 0 0;color:#{@muted};">Nothing new was published today.</p>)
  end

  defp lead(story) do
    url = safe_url(story.url)

    """
    <div style="margin-top:26px;">
      <div style="font-size:12px;line-height:16px;font-weight:600;letter-spacing:0.08em;text-transform:uppercase;color:#{@accent};">#{escape(story.section)}</div>
      <a href="#{url}" style="display:block;margin-top:8px;font-family:#{@serif};font-size:28px;line-height:34px;font-weight:700;color:#{@ink};text-decoration:none;">#{escape(story.headline)}</a>
      <p style="margin:10px 0 0;font-family:#{@serif};font-size:18px;line-height:27px;color:#{@body};">#{escape(story.standfirst)}</p>
      #{paragraph(story.paragraph)}
      <a href="#{url}" style="display:inline-block;margin-top:10px;font-size:15px;line-height:22px;font-weight:600;color:#{@accent};text-decoration:none;">Read the full story →</a>
    </div>
    """
  end

  defp paragraph(nil), do: ""
  defp paragraph(""), do: ""

  defp paragraph(text) do
    ~s(<p style="margin:10px 0 0;font-size:16px;line-height:25px;color:#{@ink};">#{escape(text)}</p>)
  end

  defp promo(edition) do
    """
    <div style="margin-top:32px;background:#{@ground};border:1px solid #{@line};border-radius:10px;padding:22px 24px;">
      <div style="font-size:11px;line-height:16px;font-weight:700;letter-spacing:0.1em;text-transform:uppercase;color:#{@muted};">From RNews1#{escape(affiliate_suffix(edition))}</div>
      <div style="margin-top:10px;font-family:#{@serif};font-size:21px;line-height:27px;font-weight:700;color:#{@ink};">Get a briefing like this for your company</div>
      <p style="margin:10px 0 0;font-size:15px;line-height:23px;color:#{@body};">#{escape(promo_body())}</p>
      <div style="margin-top:16px;">
        <a href="#{safe_url(cta_url(edition))}" style="display:inline-block;background:#{@accent};color:#ffffff;text-decoration:none;font-size:15px;line-height:20px;font-weight:600;padding:12px 20px;border-radius:8px;">Start your company's briefing</a>
        <span style="display:inline-block;margin:8px 0 0 12px;font-size:13px;line-height:18px;color:#{@muted};">$25/month · Preview free, no card</span>
      </div>
      #{disclosure_html(edition)}
    </div>
    """
  end

  defp promo_body do
    "RNews1 writes a daily news briefing about your industry, from real reporting. " <>
      "Every edition is customized to the individual recipient to maximize engagement — " <>
      "each person on your team gets the stories most likely to matter to them."
  end

  defp also_today([]), do: ""

  defp also_today(stories) do
    items =
      Enum.map_join(stories, "\n", fn s ->
        """
        <div style="padding:18px 0;border-top:1px solid #{@line};">
          <div style="font-size:11px;line-height:15px;font-weight:600;letter-spacing:0.08em;text-transform:uppercase;color:#{@accent};">#{escape(s.section)}</div>
          <a href="#{safe_url(s.url)}" style="display:block;margin-top:6px;font-family:#{@serif};font-size:19px;line-height:25px;font-weight:700;color:#{@ink};text-decoration:none;">#{escape(s.headline)}</a>
          <p style="margin:6px 0 0;font-size:15px;line-height:22px;color:#{@body};">#{escape(s.standfirst)}</p>
        </div>
        """
      end)

    """
    <div style="margin-top:34px;font-size:12px;line-height:16px;font-weight:600;letter-spacing:0.08em;text-transform:uppercase;color:#{@muted};">Also today</div>
    <div style="margin-top:6px;">#{items}</div>
    """
  end

  # The week's highlight closes the edition. It is news, so it is never boxed:
  # only the promotion is, and keeping that rule is what lets a reader tell the
  # two apart at a glance.
  defp highlight(nil), do: ""

  defp highlight(s) do
    """
    <div style="margin-top:22px;padding-top:20px;border-top:2px solid #{@ink};">
      <div style="font-size:12px;line-height:16px;font-weight:600;letter-spacing:0.08em;text-transform:uppercase;color:#{@muted};">Highlight of the week</div>
      <div style="margin-top:12px;font-size:11px;line-height:15px;font-weight:600;letter-spacing:0.08em;text-transform:uppercase;color:#{@accent};">#{escape(s.section)}</div>
      <a href="#{safe_url(s.url)}" style="display:block;margin-top:6px;font-family:#{@serif};font-size:22px;line-height:28px;font-weight:700;color:#{@ink};text-decoration:none;">#{escape(s.headline)}</a>
      <p style="margin:8px 0 0;font-size:15px;line-height:23px;color:#{@body};">#{escape(s.standfirst)}</p>
    </div>
    """
  end

  defp footer(edition) do
    unsubscribe =
      if edition.unsubscribe_url do
        ~s( <a href="#{safe_url(edition.unsubscribe_url)}" style="color:#{@ink};font-weight:600;">Unsubscribe</a> — one click, no sign-in.)
      else
        ""
      end

    """
    <div style="margin-top:12px;padding-top:18px;border-top:2px solid #{@ink};font-size:13px;line-height:20px;color:#{@muted};">
      <p style="margin:0;">#{footer_reason_html(edition)}#{unsubscribe}</p>
      <p style="margin:8px 0 0;">Every headline links to the full story, written by RNews1 from published reporting with each publisher named.</p>
      <p style="margin:8px 0 0;">RNews1 · #{escape(edition.address)}</p>
    </div>
    """
  end

  # The publication's own host, never the bare apex: rnews1.com does not resolve,
  # and each site is subscribed to at its own address.
  defp footer_reason_html(%{unsubscribe_url: nil, publication: pub, origin: origin}) do
    ~s(This is the web version of the #{escape(pub.name)} newsletter from <a href="#{safe_url(origin)}" style="color:#{@muted};">#{escape(host(origin))}</a>.)
  end

  # A business contact never subscribed, so the footer must not say they did:
  # the reason line is the one sentence in the email that has to be true of the
  # particular person reading it.
  defp footer_reason_html(%{reason: :contact, publication: pub}) do
    ~s(You're receiving the #{escape(pub.name)} newsletter as a business contact of RNews1.)
  end

  defp footer_reason_html(%{publication: pub, origin: origin}) do
    ~s(You're receiving the #{escape(pub.name)} newsletter because you subscribed at <a href="#{safe_url(origin)}" style="color:#{@muted};">#{escape(host(origin))}</a>.)
  end

  defp footer_reason_text(%{unsubscribe_url: nil, publication: pub, origin: origin}),
    do: "This is the web version of the #{pub.name} newsletter from #{host(origin)}."

  defp footer_reason_text(%{reason: :contact, publication: pub}),
    do: "You're receiving the #{pub.name} newsletter as a business contact of RNews1."

  defp footer_reason_text(%{publication: pub, origin: origin}),
    do: "You're receiving the #{pub.name} newsletter because you subscribed at #{host(origin)}."

  # ---- the affiliate slot ---------------------------------------------------------
  #
  # One input, `referral`, changes three things and never the layout: the label
  # gains the affiliate's name, the link carries their code, and a disclosure row
  # appears. The disclosure is built here from the referral, with no free-text
  # field, so whoever supplies the referral cannot reword or remove it.

  defp affiliate_suffix(%{referral: %{name: name}}) when is_binary(name) and name != "",
    do: " · Recommended by #{name}"

  defp affiliate_suffix(_), do: ""

  defp cta_url(%{app_origin: app, referral: %{code: code}}) when is_binary(code) and code != "",
    do: "#{app}/?ref=#{URI.encode_www_form(code)}"

  defp cta_url(%{app_origin: app}), do: "#{app}/"

  defp disclosure_html(%{referral: %{name: name}}) when is_binary(name) and name != "" do
    ~s(<p style="margin:16px 0 0;padding-top:12px;border-top:1px solid #{@line};font-size:12px;line-height:18px;color:#{@muted};">#{escape(name)} earns a commission if you sign up through this link. It costs you nothing extra.</p>)
  end

  defp disclosure_html(_), do: ""

  defp disclosure_text(%{referral: %{name: name}}) when is_binary(name) and name != "",
    do: "#{name} earns a commission if you sign up through this link. It costs you nothing extra."

  defp disclosure_text(_), do: nil

  defp highlight_text(nil), do: nil

  defp highlight_text(s),
    do: [
      "",
      "HIGHLIGHT OF THE WEEK",
      "#{String.upcase(s.section)}: #{s.headline}",
      s.standfirst,
      s.url
    ]

  defp host(origin), do: URI.parse(origin).host || origin
end
