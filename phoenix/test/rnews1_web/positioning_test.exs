defmodule Rnews1Web.PositioningTest do
  @moduledoc """
  RNews1 sells an automated industry newsletter built for search and email
  traffic, and every page and email it writes about itself has to say so. These
  pin the positioning (and the honesty rules that come with it) where a later
  copy edit could quietly undo it: the home page, the meta descriptions that
  search results show, the publishing gate, the dashboard and the emails RNews1
  sends on its own behalf.
  """
  use Rnews1Web.ConnCase, async: false
  alias Rnews1.{Content, Env, Subscribers, Worker}

  @published Subscribers.required_stakeholders()

  @home_line "Automated industry newsletter for search and email traffic: RNews1 writes daily stories on your topics, emails your list and gives each an indexable page."

  # Words the owner retired along with the "company brief" positioning. None of
  # them may reach a reader, though several survive as identifiers and in
  # comments, which is why these checks read rendered text, not source.
  @retired ~r/upload|enrich|stakeholder|colleague|people from your company|briefing/i

  defp meta_description(conn) do
    conn
    |> body_of()
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(meta[name="description"]))
    |> LazyHTML.attribute("content")
  end

  # What a person can read on the page: the text of the title and the body,
  # plus the attributes a browser shows (placeholders, tooltips, labels).
  # Element ids, data attributes and form names are contracts with app.js and
  # keep their old words on purpose. Whitespace is collapsed the way a browser
  # collapses it, so a sentence the template wraps still reads as one.
  defp visible_text(conn) do
    doc = conn |> body_of() |> LazyHTML.from_document()
    body = LazyHTML.query(doc, "body")

    shown =
      for attr <- ~w(placeholder title aria-label alt),
          value <- body |> LazyHTML.query("[#{attr}]") |> LazyHTML.attribute(attr),
          do: value

    [LazyHTML.text(LazyHTML.query(doc, "title")), LazyHTML.text(body) | shown]
    |> Enum.join(" ")
    |> String.replace(~r/\s+/, " ")
  end

  defp acme(conn), do: on_host(conn, "acme.rnews1.test")

  describe "the app home page" do
    test "leads with an automated industry newsletter for search and email traffic", %{conn: conn} do
      home = conn |> get("/")

      assert home.status == 200

      assert body_of(home) =~
               "<title>Automated industry newsletter for search and email traffic — "

      assert body_of(home) =~ "BUILT FOR SEARCH TRAFFIC AND EMAIL TRAFFIC"

      assert body_of(home) =~
               "Fresh pages for search, and a daily email your list has a reason to open."
    end

    test "describes itself to search engines with the home line", %{conn: conn} do
      assert meta_description(conn |> get("/")) == [@home_line]
    end

    test "no longer says upload, stakeholder or briefing anywhere a visitor can read", %{
      conn: conn
    } do
      refute visible_text(conn |> get("/")) =~ @retired
    end

    test "counts the 10 addresses toward going live, with the owner's own as the first", %{
      conn: conn
    } do
      text = visible_text(conn |> get("/"))

      assert text =~ "go live once 10 addresses are on your list, yours included"
      assert text =~ "Ten is a starting line, not a cap"
    end

    test "makes no claim that each reader's issue is personalized today", %{conn: conn} do
      text = visible_text(conn |> get("/"))

      refute text =~ ~r/personali[sz]ed/i
      refute text =~ "for their role"
    end

    test "scopes enterprise to what the code does, and keeps the way to ask for it", %{conn: conn} do
      body = body_of(conn |> get("/"))

      assert body =~
               "They include a custom domain for your news site and embeds without the RNews1 mark;"

      assert body =~ "are scoped as custom work."
      assert body =~ ~r/<a href="mailto:[^"]+">Discuss enterprise →<\/a>/
    end

    test "promises a customer's list is used only for their own newsletter", %{conn: conn} do
      assert body_of(conn |> get("/")) =~
               "Your list is used only to send your newsletter: RNews1 never mails it anything else"
    end
  end

  describe "a customer's hosted home" do
    test "describes its own coverage rather than RNews1's pitch", %{conn: conn} do
      paid_tenant(stakeholders: @published)
      home = conn |> acme() |> get("/")

      assert home.status == 200

      assert meta_description(home) == [
               "Daily Robotics news selected for Acme Robotics, following grippers. Written from published reporting, with every source named."
             ]

      assert body_of(home) =~ "<title>Acme Robotics: Robotics news — "
      refute body_of(home) =~ @home_line
      refute body_of(home) =~ Content.brand().description
    end

    test "names every keyword it follows", %{conn: conn} do
      %{tenant_id: id} = paid_tenant(stakeholders: @published)

      DB.execute(
        ~s(UPDATE tenants SET keywords = '["grippers","warehouse automation"]'::jsonb WHERE id = $1),
        [id]
      )

      assert [description] = meta_description(conn |> acme() |> get("/"))
      assert description =~ ", following grippers and warehouse automation."
    end

    test "still reads as a sentence when industry and keywords are missing", %{conn: conn} do
      %{tenant_id: id} = paid_tenant(stakeholders: @published)

      for industry <- [nil, "", "  "] do
        DB.execute("UPDATE tenants SET industry = $2, keywords = '[]'::jsonb WHERE id = $1", [
          id,
          industry
        ])

        home = conn |> acme() |> get("/")

        assert home.status == 200, inspect(industry)

        assert meta_description(home) == [
                 "Daily news selected for Acme Robotics. Written from published reporting, with every source named."
               ],
               inspect(industry)

        assert body_of(home) =~ "<title>Acme Robotics news — ", inspect(industry)
        assert body_of(home) =~ ~s(<p class="eyebrow">Daily news</p>), inspect(industry)
      end
    end

    test "does not say news twice when the industry already ends in it", %{conn: conn} do
      %{tenant_id: id} = paid_tenant(stakeholders: @published)
      DB.execute("UPDATE tenants SET industry = 'Fashion News' WHERE id = $1", [id])

      home = body_of(conn |> acme() |> get("/"))
      feed = body_of(conn |> acme() |> get("/feed.xml"))

      assert home =~
               ~s(content="Daily Fashion News selected for Acme Robotics, following grippers.)

      assert home =~ "<title>Acme Robotics: Fashion News — "
      assert home =~ ~s(<p class="eyebrow">Daily Fashion News</p>)

      assert feed =~
               "<description>Daily Fashion News from Acme Robotics, written by RNews1</description>"

      refute home =~ ~r/news news/i
      refute feed =~ ~r/news news/i
    end

    test "labels coverage by industry, adding news only where it is missing" do
      assert Rnews1Web.Templates.news_label("Robotics") == "Robotics news"
      assert Rnews1Web.Templates.news_label("Fashion News") == "Fashion News"
      assert Rnews1Web.Templates.news_label("  fintech news ") == "fintech news"
      assert Rnews1Web.Templates.news_label("Newsletters") == "Newsletters news"
      assert Rnews1Web.Templates.news_label(nil) == "news"
      assert Rnews1Web.Templates.news_label("  ") == "news"
    end

    test "escapes the company and its topics in the description and the title", %{conn: conn} do
      %{tenant_id: id} = paid_tenant(stakeholders: @published)
      DB.execute(~s(UPDATE tenants SET name = '"Acme" <b>', industry = 'R&D' WHERE id = $1), [id])
      body = body_of(conn |> acme() |> get("/"))

      assert body =~ ~s(content="Daily R&amp;D news selected for &quot;Acme&quot; &lt;b&gt;)
      refute body =~ "<b>"

      assert meta_description(conn |> acme() |> get("/")) == [
               ~s(Daily R&D news selected for "Acme" <b>, following grippers. Written from published reporting, with every source named.)
             ]
    end
  end

  describe "story pages" do
    test "a hosted story is described by its own standfirst", %{conn: conn} do
      %{story: story} = paid_tenant(stakeholders: @published)
      page = conn |> acme() |> get("/news/#{story.id}")

      assert page.status == 200
      assert meta_description(page) == ["What it means for operators."]
    end

    test "a hosted story with an empty standfirst falls back to the brand description", %{
      conn: conn
    } do
      %{story: story} = paid_tenant(stakeholders: @published)
      DB.execute("UPDATE stories SET standfirst = '' WHERE id = $1", [story.id])

      assert meta_description(conn |> acme() |> get("/news/#{story.id}")) == [
               Content.brand().description
             ]
    end

    test "a www article is described by its own standfirst", %{conn: conn} do
      archive_story(%{standfirst: "Three agencies opened an inquiry."})
      page = conn |> on_host("www.rnews1.test") |> get("/en/usa/a-thing-that-happened/2026-08-29")

      assert page.status == 200
      assert meta_description(page) == ["Three agencies opened an inquiry."]
    end

    test "a www section page falls back to a brand description written for a news reader", %{
      conn: conn
    } do
      archive_story()
      [description] = meta_description(conn |> on_host("www.rnews1.test") |> get("/en"))

      assert description == Content.brand().description

      assert description =~ "RNews1 writes daily news from published reporting"

      # The www archive shows no source credit, and imported stories have none
      # to show, so the description may not promise one.
      refute description =~ "every publisher"
      refute description =~ @home_line
      refute description =~ "$25"
    end

    test "the built-in brand description matches the one content.json ships" do
      shipped =
        Content.file() |> File.read!() |> Jason.decode!() |> get_in(["brand", "description"])

      assert Content.brand_defaults().description == shipped
    end
  end

  describe "the publishing gate" do
    test "an unpublished customer site asks for an active subscription and 10 addresses", %{
      conn: conn
    } do
      paid_tenant(stakeholders: @published - 2)
      page = conn |> acme() |> get("/")

      assert page.status == 409

      assert visible_text(page) =~
               "It goes live once its subscription is active and #{@published} addresses are on its newsletter list."

      refute visible_text(page) =~ @retired
    end

    test "an unpublished feed answers 409 with the same two conditions", %{conn: conn} do
      %{tenant: tenant} = paid_tenant(stakeholders: @published - 2)
      feed = conn |> get("/feed/#{tenant.public_token}.xml")

      assert feed.status == 409

      assert body_of(feed) =~
               "It goes live once the subscription is active and #{@published} addresses are on the newsletter list."

      refute body_of(feed) =~ @retired
    end
  end

  describe "the dashboard" do
    test "speaks of recipients and addresses, never stakeholders, colleagues or a briefing", %{
      conn: conn
    } do
      %{tenant_id: id} = paid_tenant()
      page = conn |> as_tenant(session_for(id)) |> get("/app")
      text = visible_text(page)

      assert page.status == 200
      assert text =~ "Recipient email" and text =~ "Newsletter language"
      assert text =~ "once 10 are on your list, your site, RSS feed and embed go live"
      refute text =~ @retired
    end
  end

  describe "emails RNews1 sends on its own behalf" do
    defp campaign do
      Worker.build_message(%{
        kind: "campaign",
        payload: %{"name" => "Dana", "unsubscribeUrl" => "https://rnews1.test/u/tok"},
        contact_id: nil,
        tenant_id: nil
      })
    end

    test "the sales campaign pitches an industry newsletter you never have to write" do
      email = campaign()

      assert email.subject == "An industry newsletter you never have to write"
      assert email.text =~ "RNews1 writes a daily industry newsletter."
      refute email.text =~ @retired
      refute email.html =~ @retired
    end

    test "the sales campaign says it is promotional, in the text and the HTML" do
      email = campaign()

      assert email.text =~ "This is a promotional email from RNews1."
      assert email.html =~ "This is a promotional email from RNews1."
    end

    test "the sales campaign keeps its one-click unsubscribe and the postal address" do
      email = campaign()
      address = Env.business_address()

      assert email.text =~ "Unsubscribe: https://rnews1.test/u/tok"
      assert email.text =~ "RNews1, #{address}"
      assert email.html =~ ~s(href="https://rnews1.test/u/tok")
      assert email.html =~ "RNews1 · #{address}"
      assert email.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
      assert email.tag == "campaign"
    end

    test "the dormant confirmation asks about a newsletter, with or without a company" do
      named =
        Worker.build_message(%{
          kind: "confirmation",
          payload: %{"company" => "Acme <b>", "url" => "https://rnews1.test/confirm/t"},
          contact_id: nil,
          tenant_id: nil
        })

      assert named.subject == "Confirm your Acme <b> newsletter"

      assert named.text =~
               "Acme <b> has invited you to receive its daily industry newsletter, written by RNews1."

      assert named.html =~ "Acme &lt;b&gt; has invited you"
      refute named.html =~ "<b>"

      for company <- [nil, ""] do
        anonymous =
          Worker.build_message(%{
            kind: "confirmation",
            payload: %{"company" => company, "url" => "https://rnews1.test/confirm/t"},
            contact_id: nil,
            tenant_id: nil
          })

        assert anonymous.subject == "Confirm your newsletter subscription"
        assert anonymous.text =~ "A company has invited you"
        refute anonymous.text =~ @retired
      end
    end
  end
end
