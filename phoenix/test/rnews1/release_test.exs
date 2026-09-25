defmodule Rnews1.ReleaseTest do
  use Rnews1.DataCase, async: false
  alias Rnews1.Release

  test "maps the Node app's applied SQL files onto the Ecto versions that run them" do
    assert Release.adoptable_versions([
             "001_initial.sql",
             "009_custom_domains.sql",
             "999_never.sql"
           ]) ==
             [20_260_101_000_001, 20_260_101_000_009]

    assert Release.adoptable_versions([]) == []
  end

  test "adopts a database with Node bookkeeping and leaves one without alone" do
    assert Release.adopt_node_migrations(Rnews1.Repo) == :none

    Ecto.Adapters.SQL.query!(
      Rnews1.Repo,
      "CREATE TABLE schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())"
    )

    Ecto.Adapters.SQL.query!(
      Rnews1.Repo,
      "INSERT INTO schema_migrations(name) VALUES ('001_initial.sql'), ('002_newsletters_and_ads.sql')"
    )

    assert {:adopted, [20_260_101_000_001, 20_260_101_000_002]} =
             Release.adopt_node_migrations(Rnews1.Repo)

    source = Rnews1.Repo.config()[:migration_source]

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Rnews1.Repo,
        "SELECT version FROM #{source} WHERE version <= 20260101000002 ORDER BY version"
      )

    assert rows == [[20_260_101_000_001], [20_260_101_000_002]]
  end

  test "cli/2 refuses an operation the CLI does not have, before it touches the application" do
    before = Application.get_env(:rnews1, :start_workers)

    assert_raise ArgumentError, "Rnews1.CLI has no nope/1", fn -> Release.cli(:nope, []) end

    assert Application.get_env(:rnews1, :start_workers) == before
  end

  test "cli/2 runs a CLI operation without the web listener or the worker loops" do
    output = ExUnit.CaptureIO.capture_io(fn -> assert :ok = Release.cli(:login, []) end)

    assert output =~ "No sign-in links queued"
    assert Application.get_env(:rnews1, :start_workers) == false
    assert Application.get_env(:rnews1, Rnews1Web.Endpoint)[:server] == false
  end
end
