defmodule Rnews1.Import do
  @moduledoc "Bringing content in: the Hugo tree, and the CSV export the Node deploy made."
  alias Rnews1.{DB, Stories}

  @languages MapSet.new(~w(ar bn en es fr hi it la pt ru ur zh))

  def hugo([root | rest]) do
    dry_run = "--dry-run" in rest
    files = root |> Path.expand() |> walk() |> Enum.sort()

    {parsed, skipped} =
      Enum.reduce(files, {[], []}, fn file, {ok, bad} ->
        case read(file, Path.expand(root)) do
          {:ok, nil} -> {ok, bad ++ [{file, "not an article"}]}
          {:ok, article} -> {ok ++ [article], bad}
          {:error, reason} -> {ok, bad ++ [{file, reason}]}
        end
      end)

    groups = Enum.group_by(parsed, & &1.slug)
    IO.inspect(%{files: length(files), articles: length(parsed), translation_groups: map_size(groups), skipped: length(skipped), dry_run: dry_run})

    if not dry_run do
      for article <- parsed, do: Stories.upsert_import(article)
      IO.puts("written: #{length(parsed)}")
    end

    for {file, reason} <- Enum.take(skipped, 10), do: IO.puts("  skipped #{Path.basename(file)} — #{reason}")
  end

  def hugo(_), do: IO.puts("Usage: mix rnews1.import_hugo ../hugo/content [--dry-run]")

  defp walk(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      full = Path.join(dir, name)

      cond do
        File.dir?(full) -> walk(full)
        String.ends_with?(name, ".md") and name != "_index.md" -> [full]
        true -> []
      end
    end)
  end

  defp read(file, root) do
    [language | rest] = file |> Path.relative_to(root) |> Path.split()

    if not MapSet.member?(@languages, language) or rest == [] do
      {:ok, nil}
    else
      raw = File.read!(file)

      case Regex.run(~r/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/, raw) do
        [_, front, body] ->
          with {:ok, meta} <- frontmatter(front) do
            if meta["draft"] == true do
              {:ok, nil}
            else
              slug = Path.basename(file, ".md")

              {:ok,
               %{
                 language: language,
                 slug: slug,
                 translation_key: to_string(meta["translationKey"] || slug) |> String.trim(),
                 category: first(meta["categories"]) || hd(rest),
                 title: to_string(meta["title"] || slug) |> String.trim(),
                 description: to_string(meta["description"] || "") |> String.trim(),
                 body: body |> String.trim() |> String.replace(~r/^#\s+.*\r?\n+/, "") |> String.trim(),
                 tags: meta["tags"] |> List.wrap() |> Enum.map(&to_string/1),
                 published_at: date(meta["date"])
               }}
            end
          end

        _ ->
          {:error, "no frontmatter"}
      end
    end
  end

  # Twenty files carry a `tweet:` value YAML cannot read; it is dropped and the parse retried.
  defp frontmatter(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:ok, %{}}
      {:error, _} ->
        case YamlElixir.read_from_string(without_tweet(text)) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> {:error, "unparseable frontmatter"}
        end
    end
  end

  def without_tweet(text) do
    {kept, _, _} =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({[], false, 0}, fn line, {kept, skipping, quotes} ->
        skipping = skipping or Regex.match?(~r/^tweet:/, line)

        if not skipping do
          {kept ++ [line], false, 0}
        else
          quotes = quotes + (line |> String.graphemes() |> Enum.count(&(&1 == "\"")))
          {kept, rem(quotes, 2) != 0, quotes}
        end
      end)

    Enum.join(kept, "\n")
  end

  defp first(list) when is_list(list), do: list |> List.first() |> then(&(&1 && &1 |> to_string() |> String.trim("\"") |> String.trim()))
  defp first(nil), do: nil
  defp first(value), do: value |> to_string() |> String.trim("\"") |> String.trim()

  defp date(%DateTime{} = dt), do: dt
  defp date(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
  defp date(%Date{} = d), do: DateTime.new!(d, ~T[12:00:00], "Etc/UTC")

  defp date(value) do
    text = to_string(value || "")

    case DateTime.from_iso8601(text) do
      {:ok, dt, _} -> dt
      _ ->
        case DateTime.from_iso8601(String.replace(text, " ", "T", global: false)) do
          {:ok, dt, _} -> dt
          _ -> DateTime.utc_now()
        end
    end
  end

  @doc "Loads the CSV export from the Node deploy when the stories table is empty."
  def load_content(args) do
    file = Enum.find(args, &(not String.starts_with?(&1, "--"))) || Path.join(File.cwd!(), "deploy/content.csv.gz")

    cond do
      not File.exists?(file) ->
        IO.puts("No export at #{file}; nothing loaded.")

      DB.value("SELECT count(*) FROM stories") > 0 ->
        IO.puts("stories table is not empty; not loading #{file}.")

      true ->
        csv = file |> File.read!() |> :zlib.gunzip()
        [header | _] = String.split(csv, "\n", parts: 2)
        columns = header |> String.trim() |> String.split(",")

        # COPY FROM STDIN by column name, so the export survives a later
        # migration that adds a column in a different position.
        Rnews1.Repo.transaction(fn ->
          stream = Ecto.Adapters.SQL.stream(Rnews1.Repo, "COPY stories (#{Enum.join(columns, ",")}) FROM STDIN CSV HEADER", [])
          Enum.into([csv], stream)
        end, timeout: :infinity)

        IO.puts("loaded: #{DB.value("SELECT count(*) FROM stories")} stories in #{DB.value("SELECT count(DISTINCT language) FROM stories")} languages")
    end
  end
end
