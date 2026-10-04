defmodule Rnews1.EditionsTest do
  @moduledoc """
  The newsletter edition: one template, every publication, one day at a time.
  """
  use Rnews1.DataCase, async: false
  alias Rnews1.{EditionMail, Editions, Publications}

  @day "2026-09-10"

  setup do
    archive = publication()

    fashion =
      Publications.create(%{
        slug: "fashion",
        name: "FashionShowOn",
        hostname: "fashionshowon.rnews1.test",
        tagline: "Runway, beauty and the business of fashion.",
        languages: ["en"],
        sections: [%{name: "Runway", query: "runway"}]
      })

    story(archive, "nvidia-allocates-chips", "Technology", "NVIDIA allocates chips with AI", @day,
      body:
        "## Context\n\nNVIDIA is using **optimization** and [a model](https://example.com/x) to allocate components.\n\nMore follows."
    )

    story(archive, "franklin-on-the-seven", "Business", "Franklin on the Magnificent Seven", @day)
    story(fashion, "moschino-restraint", "Runway", "Moschino chooses restraint", @day)

    %{archive: archive, fashion: fashion}
  end

  defp story(pub, slug, category, headline, date, opts \\ []) do
    archive_story(%{
      publication_id: pub.id,
      language: Keyword.get(opts, :language, "en"),
      slug: slug,
      translation_key: slug,
      category: category,
      headline: headline,
      standfirst: "#{headline}, in a sentence.",
      body: Keyword.get(opts, :body, "A paragraph about #{headline}."),
      issue_date: date,
      published_at: Keyword.get(opts, :at, ~U[2026-09-10 08:00:00Z])
    })
  end

  defp html(pub, opts \\ []),
    do: pub |> Editions.build(Keyword.put_new(opts, :date, @day)) |> EditionMail.render_html()

  test "every publication gets its own edition: its own name, stories and host", %{
    archive: archive,
    fashion: fashion
  } do
    a = html(archive)
    f = html(fashion)

    assert a =~ "RNews1" and a =~ "Real News, made for One."
    assert a =~ "NVIDIA allocates chips with AI"
    refute a =~ "Moschino chooses restraint"
    assert a =~ "www.rnews1.test"

    assert f =~ "FashionShowOn" and f =~ "Runway, beauty and the business of fashion."
    assert f =~ "Moschino chooses restraint"
    refute f =~ "NVIDIA allocates chips with AI"
    assert f =~ "fashionshowon.rnews1.test"
    refute f =~ "www.rnews1.test/en"
  end

  test "links every story to its /en version, even on a publication that runs other languages", %{
    archive: archive
  } do
    story(archive, "nvidia-allocates-chips", "Technology", "NVIDIA asigna chips", @day,
      language: "es"
    )

    a = html(archive)
    assert a =~ "https://www.rnews1.test/en/technology/nvidia-allocates-chips/#{@day}"
    refute a =~ "/es/"
    refute a =~ "NVIDIA asigna chips"
  end

  test "labels the promotion as from RNews1 and never as an advertisement", %{archive: archive} do
    a = html(archive)

    assert a =~ "From RNews1"
    assert a =~ "customized to the individual recipient"
    refute a =~ ~r/advertisement/i
    refute a =~ ">Ad<"
  end

  test "the web version says so; an emailed copy carries a one-click unsubscribe", %{
    archive: archive
  } do
    web = html(archive)
    assert web =~ "web version of the RNews1 newsletter"
    refute web =~ "Unsubscribe"
    refute web =~ "you subscribed"

    mailed = html(archive, unsubscribe_url: "https://rnews1.test/u/tok")
    assert mailed =~ "because you subscribed at"
    assert mailed =~ ~s(href="https://rnews1.test/u/tok")
    assert mailed =~ "View in a browser"
  end

  test "an affiliate edition names the affiliate, carries their code and discloses the commission",
       %{archive: archive} do
    plain = html(archive)
    refute plain =~ "commission"
    refute plain =~ "?ref="

    sent = html(archive, referral: %{name: "Acme Media", code: "acme-7"})
    assert sent =~ "From RNews1 · Recommended by Acme Media"
    assert sent =~ "?ref=acme-7"
    assert sent =~ "Acme Media earns a commission if you sign up through this link."
  end

  test "escapes everything it is given", %{archive: archive} do
    story(archive, "bad-headline", "Technology", ~s[<script>alert("x")</script> headline], @day,
      at: ~U[2026-09-10 09:00:00Z]
    )

    a = html(archive, referral: %{name: ~s(<b>Evil</b>), code: ~s("><x)})
    refute a =~ "<script>alert"
    refute a =~ "<b>Evil</b>"
    assert a =~ "&lt;script&gt;"
    refute a =~ ~s("><x)
  end

  test "a day with nothing published has no edition, so nothing empty is sent", %{
    fashion: fashion
  } do
    assert Editions.build(fashion, date: "2026-09-11") == nil
  end

  test "the week's highlight is its most clicked-through story, never one from the edition's own day",
       %{archive: archive} do
    story(archive, "quiet-tuesday", "World", "A quiet Tuesday story", "2026-09-08",
      at: ~U[2026-09-08 08:00:00Z]
    )

    story(archive, "busy-monday", "Science", "The story everyone read", "2026-09-07",
      at: ~U[2026-09-07 08:00:00Z]
    )

    click = fn kind, path, target ->
      Rnews1.DB.execute(
        "INSERT INTO click_events(host, path, kind, target) VALUES($1, $2, $3, $4)",
        [
          archive.hostname,
          path,
          kind,
          target
        ]
      )
    end

    # Three click-throughs TO the Monday story, from the section page.
    for _ <- 1..3, do: click.("link", "/en/science", "/en/science/busy-monday/2026-09-07")

    # Plenty of clicks made while ON the Tuesday story — which are not reads of it.
    for _ <- 1..5, do: click.("link", "/en/world/quiet-tuesday/2026-09-08", "/en")

    edition = Editions.build(archive, date: @day)
    assert edition.highlight.headline == "The story everyone read"

    # Nothing from the edition's own day can be the highlight, however read.
    refute edition.highlight.headline in [
             "NVIDIA allocates chips with AI",
             "Franklin on the Magnificent Seven"
           ]

    assert EditionMail.render_html(edition) =~ "Highlight of the week"
  end

  test "with no reads at all, the highlight falls back to the newest story of the week", %{
    archive: archive
  } do
    story(archive, "older", "World", "Older story", "2026-09-05", at: ~U[2026-09-05 08:00:00Z])
    story(archive, "newer", "World", "Newer story", "2026-09-08", at: ~U[2026-09-08 08:00:00Z])

    assert Editions.build(archive, date: @day).highlight.headline == "Newer story"
  end

  test "the lead's opening paragraph skips headings and drops Markdown" do
    body = "## A heading\n\nWith **bold**, _italic_ and [a link](https://x.test/y).\n\nSecond."
    assert Editions.opening_paragraph(body) == "With bold, italic and a link."
  end

  test "the plain-text copy carries the same edition", %{archive: archive} do
    text =
      archive
      |> Editions.build(date: @day, unsubscribe_url: "https://rnews1.test/u/tok")
      |> EditionMail.render_text()

    assert text =~ "RNews1 — Real News, made for One."
    assert text =~ "NVIDIA allocates chips with AI"
    assert text =~ "FROM RNEWS1"
    assert text =~ "https://rnews1.test/u/tok"
    refute text =~ ~r/advertisement/i
  end
end
