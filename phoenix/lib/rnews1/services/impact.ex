defmodule Rnews1.Impact do
  @moduledoc "Which parts of the news bear on one person's working life."
  require Logger
  alias Rnews1.{AI, Editorial}

  @defaults ["Business", "Technology", "World"]
  def default_sections, do: @defaults

  def sections_for(reader, limit \\ 4) do
    title = reader[:title]
    company = reader[:company]
    industry = reader[:industry]

    if is_nil(title) and is_nil(company) and is_nil(industry) do
      %{sections: defaults(limit, "A general selection — we know nothing about this reader yet."), personalised: false}
    else
      instruction =
        Enum.join(
          [
            "You decide which parts of the news bear on one person's working life.",
            "",
            "Choose #{limit} sections from this list, most consequential first:",
            Enum.join(Editorial.categories(), ", "),
            "",
            "Judge by what would change how this person does their job, what their",
            "employer is exposed to, and what their market reacts to. A section is not",
            "relevant merely because it is important in general.",
            "",
            "For each, give one sentence — under 25 words — saying why it bears on",
            "this particular person. Address the reason to their role, not to the",
            "section: 'ransomware disclosure rules decide what your team must report',",
            "not 'compliance news is important'.",
            "",
            ~s(Return {"sections":[{"name":"...","why":"..."}]} using only names from),
            "the list above."
          ],
          "\n"
        )

      try do
        output = AI.json(instruction, %{title: title, company: company, industry: industry}, max_retries: 1)

        sections =
          output
          |> Map.get("sections", [])
          |> List.wrap()
          |> Enum.map(fn entry -> %{name: Editorial.match_category(entry["name"]), why: (entry["why"] || "") |> to_string() |> String.trim() |> String.slice(0, 200)} end)
          |> Enum.filter(& &1.name)
          |> Enum.take(limit)
          |> Enum.uniq_by(& &1.name)

        if sections == [], do: raise("no usable sections returned")
        %{sections: sections, personalised: true}
      rescue
        e ->
          Logger.warning("Section ranking failed, using defaults: #{Exception.message(e)}")
          %{sections: defaults(limit, "A general selection — this reader's sections could not be ranked."), personalised: false}
      end
    end
  end

  defp defaults(limit, why), do: @defaults |> Enum.take(limit) |> Enum.map(&%{name: &1, why: why})
end

defmodule Rnews1.Reports do
  @moduledoc "A report built for one reader, stored as an ordinary brief row."
  alias Rnews1.{Briefs, Impact, Stories}

  def build_custom_report(contact, opts \\ []) do
    language = Keyword.get(opts, :language, "en")
    section_count = Keyword.get(opts, :section_count, 4)
    per_section = Keyword.get(opts, :per_section, 2)

    ranked = Impact.sections_for(%{title: contact[:title], company: contact[:company], industry: contact[:industry]}, section_count)
    selected = Stories.recent_by_section(%{language: language, sections: Enum.map(ranked.sections, & &1.name), per_section: per_section})

    meta = %{
      reader: %{name: contact[:name], title: contact[:title], company: contact[:company], industry: contact[:industry]},
      sections: ranked.sections,
      personalised: ranked.personalised,
      language: language
    }

    issue_date = Date.utc_today() |> Date.to_iso8601()

    id =
      Briefs.create(%{
        tenant_id: Keyword.get(opts, :tenant_id),
        contact_id: contact[:id],
        html: "",
        story_ids: Enum.map(selected, & &1.id),
        issue_date: issue_date,
        meta: meta
      })

    %{id: id, sections: ranked.sections, personalised: ranked.personalised, stories: length(selected), issue_date: issue_date}
  end
end
