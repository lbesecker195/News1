defmodule Rnews1.PDF do
  @moduledoc """
  The brief page, rendered to PDF by a real Chrome through ChromicPDF.

  One page, always. Headlines vary, so the print is scaled down step by step
  until it fits a sheet; a briefing at 85% reads fine, one that spills three
  lines onto a second page reads as broken. Chrome is optional at boot — no
  Chrome means PDFs are unavailable, and everything else works.
  """
  require Logger
  alias Rnews1.Env
  alias Rnews1.Util.Ids

  @scales [1.0, 0.92, 0.85, 0.78, 0.7, 0.62]
  def min_scale, do: List.last(@scales)

  def brief_pdf_path(id) do
    if not Ids.uuid?(id), do: raise(ArgumentError, "A brief id must be a UUID.")
    Path.join(Env.pdf_dir(), "#{id}.pdf")
  end

  @doc """
  Where Chrome is, if anywhere: config, PATH, the puppeteer cache, or the Mac
  app. `CHROME_EXECUTABLE=none` switches PDFs off on purpose.
  """
  def chrome_path do
    if Env.chrome_executable() in ["none", "off", "0"], do: nil, else: find_chrome()
  end

  defp find_chrome do
    candidates =
      [Env.chrome_executable()] ++
        Enum.map(
          ~w(google-chrome google-chrome-stable chromium chromium-browser chrome),
          &System.find_executable/1
        ) ++
        Path.wildcard(
          Path.expand(
            "~/.cache/puppeteer/chrome/*/chrome-*/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
          )
        ) ++
        Path.wildcard(Path.expand("~/.cache/puppeteer/chrome/*/chrome-linux64/chrome")) ++
        ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]

    Enum.find(candidates, &(is_binary(&1) and File.exists?(&1) and not snap_shim?(&1)))
  end

  # Ubuntu's chromium packages install a script that runs the snap, which a
  # hardened service cannot execute. Treat it as no browser at all.
  defp snap_shim?(path) do
    case File.read(path) do
      {:ok, <<"#!", _::binary>> = script} -> String.contains?(script, "/snap/bin/")
      _ -> false
    end
  end

  def available?, do: Process.whereis(ChromicPDF) != nil

  @doc """
  The child spec for the application supervisor; nil when there is no Chrome.

  Chrome is started beside the app rather than in it (`Rnews1.PDF.Starter`):
  a browser that cannot run here — a snap under a hardened service, a broken
  install — costs the PDFs and nothing else, where a crashing child in the
  application tree would take the whole node down with it.
  """
  def child_spec_if_available do
    case chrome_path() do
      nil ->
        nil

      path ->
        {Rnews1.PDF.Starter,
         [
           chrome_executable: path,
           no_sandbox: Env.chrome_no_sandbox?(),
           chrome_args: "--disable-dev-shm-usage",
           session_pool: [size: 1, timeout: 30_000],
           on_demand: false
         ]}
    end
  end

  def html_to_pdf(html, print \\ %{}) do
    if not available?(), do: raise("PDF rendering is unavailable: no Chrome found")

    one_page = Map.get(print, :one_page, true)

    if one_page do
      Enum.reduce_while(@scales, nil, fn scale, _ ->
        pdf = print_at(html, scale)
        if page_count(pdf) <= 1, do: {:halt, pdf}, else: {:cont, pdf}
      end)
      |> tap(fn pdf ->
        if page_count(pdf) > 1,
          do:
            Logger.warning(
              "Brief PDF does not fit one page even at #{min_scale() * 100}%; printing as is."
            )
      end)
    else
      print_at(html, 1.0)
    end
  end

  defp print_at(html, scale) do
    {:ok, base64} =
      ChromicPDF.print_to_pdf({:html, html},
        print_to_pdf: %{preferCSSPageSize: true, printBackground: true, scale: scale}
      )

    Base.decode64!(base64)
  end

  @doc "Chrome's PDFs carry `/Type /Pages … /Count N` in plain text."
  def page_count(pdf) when is_binary(pdf) do
    case Regex.run(~r/\/Type\s*\/Pages[^>]*?\/Count\s+(\d+)/s, pdf) do
      [_, n] -> String.to_integer(n)
      _ -> 1
    end
  end

  def write_brief_pdf(id, html, print \\ %{}) do
    target = brief_pdf_path(id)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, html_to_pdf(html, print))
    target
  end

  def delete_brief_pdf(id) do
    case File.rm(brief_pdf_path(id)) do
      :ok -> true
      {:error, :enoent} -> false
      {:error, reason} -> raise "could not delete PDF: #{inspect(reason)}"
    end
  end
end
