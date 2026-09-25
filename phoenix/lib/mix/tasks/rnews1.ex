defmodule Mix.Tasks.Rnews1.Admin do
  @shortdoc "Create or update a platform admin: mix rnews1.admin <email> <password> [--comp]"
  use Mix.Task
  def run(args), do: (Mix.Task.run("app.start", ["--no-start"]); {:ok, _} = Application.ensure_all_started(:rnews1); Rnews1.CLI.create_admin(args))
end

defmodule Mix.Tasks.Rnews1.Login do
  @shortdoc "Print a sign-in link: mix rnews1.login [email]"
  use Mix.Task
  def run(args), do: (Mix.Task.run("app.start", ["--no-start"]); {:ok, _} = Application.ensure_all_started(:rnews1); Rnews1.CLI.login(args))
end

defmodule Mix.Tasks.Rnews1.Content do
  @shortdoc "Write the journal: mix rnews1.content [--dry-run] [--category X] [--languages a,b]"
  use Mix.Task
  def run(args), do: (Mix.Task.run("app.start", ["--no-start"]); {:ok, _} = Application.ensure_all_started(:rnews1); Rnews1.CLI.content(args))
end

defmodule Mix.Tasks.Rnews1.Translate do
  @shortdoc "Backfill missing locales: mix rnews1.translate [--dry-run] [--limit N]"
  use Mix.Task
  def run(args), do: (Mix.Task.run("app.start", ["--no-start"]); {:ok, _} = Application.ensure_all_started(:rnews1); Rnews1.CLI.translate(args))
end

defmodule Mix.Tasks.Rnews1.Report do
  @shortdoc "Build a custom report: mix rnews1.report --title X --company Y"
  use Mix.Task
  def run(args), do: (Mix.Task.run("app.start", ["--no-start"]); {:ok, _} = Application.ensure_all_started(:rnews1); Rnews1.CLI.custom_report(args))
end

defmodule Mix.Tasks.Rnews1.Pdf do
  @shortdoc "Print a brief to PDF: mix rnews1.pdf <brief-id> [--out file]"
  use Mix.Task
  def run(args), do: (Mix.Task.run("app.start", ["--no-start"]); {:ok, _} = Application.ensure_all_started(:rnews1); Rnews1.CLI.pdf(args))
end

defmodule Mix.Tasks.Rnews1.Clicks do
  @shortdoc "What readers click: mix rnews1.clicks [--days N] [--host H]"
  use Mix.Task
  def run(args), do: (Mix.Task.run("app.start", ["--no-start"]); {:ok, _} = Application.ensure_all_started(:rnews1); Rnews1.CLI.clicks(args))
end

defmodule Mix.Tasks.Rnews1.Plan do
  @shortdoc "Queue the outbound campaign: mix rnews1.plan YYYY-MM-DD"
  use Mix.Task
  def run(args), do: (Mix.Task.run("app.start", ["--no-start"]); {:ok, _} = Application.ensure_all_started(:rnews1); Rnews1.CLI.plan(args))
end

defmodule Mix.Tasks.Rnews1.Once do
  @shortdoc "One pass of every worker loop"
  use Mix.Task
  def run(args), do: (Mix.Task.run("app.start", ["--no-start"]); {:ok, _} = Application.ensure_all_started(:rnews1); Rnews1.CLI.once(args))
end

defmodule Mix.Tasks.Rnews1.Content.Load do
  @shortdoc "Load deploy/content.csv.gz (the archive export) into an empty stories table"
  use Mix.Task
  def run(args), do: (Mix.Task.run("app.start", ["--no-start"]); {:ok, _} = Application.ensure_all_started(:rnews1); Rnews1.Import.load_content(args))
end

defmodule Mix.Tasks.Rnews1.ImportHugo do
  @shortdoc "Import the Hugo content directory: mix rnews1.import_hugo ../hugo/content [--dry-run]"
  use Mix.Task
  def run(args), do: (Mix.Task.run("app.start", ["--no-start"]); {:ok, _} = Application.ensure_all_started(:rnews1); Rnews1.Import.hugo(args))
end
