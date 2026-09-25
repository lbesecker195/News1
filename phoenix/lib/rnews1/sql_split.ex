defmodule Rnews1.SQLSplit do
  @moduledoc """
  Splits a SQL file into statements. Postgrex speaks the extended protocol,
  which takes one statement per query; node-postgres ran a parameterless
  string through the simple protocol and Postgres split it. The splitter
  respects dollar-quoted bodies ($$ … $$, $tag$ … $tag$), string literals,
  and both comment forms, because the migrations carry DO blocks whose
  bodies are full of semicolons.
  """

  def statements(sql) do
    sql |> scan([], [], :code) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  # state machine over the text; `acc` is the current statement in reverse
  defp scan("", acc, done, _), do: Enum.reverse([flush(acc) | done])

  defp scan(<<";", rest::binary>>, acc, done, :code), do: scan(rest, [], [flush(acc) | done], :code)
  defp scan(<<"--", rest::binary>>, acc, done, :code), do: skip_line(rest, ["--" | acc], done)
  defp scan(<<"/*", rest::binary>>, acc, done, :code), do: skip_block(rest, ["/*" | acc], done)
  defp scan(<<"'", rest::binary>>, acc, done, :code), do: scan(rest, ["'" | acc], done, :string)

  defp scan(<<"$", rest::binary>> = text, acc, done, :code) do
    case Regex.run(~r/^\$([A-Za-z_][A-Za-z0-9_]*)?\$/, text) do
      [tag | _] ->
        {body, after_body} = until_tag(binary_part(rest, String.length(tag) - 1, byte_size(rest) - String.length(tag) + 1), tag)
        scan(after_body, [tag <> body <> tag | acc], done, :code)

      _ ->
        scan(rest, ["$" | acc], done, :code)
    end
  end

  defp scan(<<char::utf8, rest::binary>>, acc, done, :code), do: scan(rest, [<<char::utf8>> | acc], done, :code)

  defp scan(<<"''", rest::binary>>, acc, done, :string), do: scan(rest, ["''" | acc], done, :string)
  defp scan(<<"'", rest::binary>>, acc, done, :string), do: scan(rest, ["'" | acc], done, :code)
  defp scan(<<char::utf8, rest::binary>>, acc, done, :string), do: scan(rest, [<<char::utf8>> | acc], done, :string)

  defp skip_line(text, acc, done) do
    case String.split(text, "\n", parts: 2) do
      [comment, rest] -> scan(rest, ["\n", comment | acc], done, :code)
      [comment] -> scan("", [comment | acc], done, :code)
    end
  end

  defp skip_block(text, acc, done) do
    case String.split(text, "*/", parts: 2) do
      [comment, rest] -> scan(rest, ["*/", comment | acc], done, :code)
      [comment] -> scan("", [comment | acc], done, :code)
    end
  end

  defp until_tag(text, tag) do
    case String.split(text, tag, parts: 2) do
      [body, rest] -> {body, rest}
      [body] -> {body, ""}
    end
  end

  defp flush(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
end
