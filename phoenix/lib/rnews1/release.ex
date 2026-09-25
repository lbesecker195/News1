defmodule Rnews1.Release do
  @moduledoc "Tasks a release can run without Mix: `bin/rnews1 eval 'Rnews1.Release.migrate()'`."
  @app :rnews1

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          adopt_node_migrations(repo)
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end
  end

  @doc """
  Adopts a database the Node app built. Its bookkeeping is `schema_migrations(name)`,
  one row per SQL file; every Ecto migration here runs one of those same files.
  So whatever Node already applied is recorded as applied for Ecto too (in its
  own table, `migration_source`), and only the files Node never saw are run.
  A database without that table — one this app created — is left alone.
  """
  def adopt_node_migrations(repo) do
    source = repo.config()[:migration_source] || "schema_migrations"

    with true <- source != "schema_migrations",
         {:ok, %{rows: [[true]]}} <-
           Ecto.Adapters.SQL.query(
             repo,
             "SELECT to_regclass('public.schema_migrations') IS NOT NULL"
           ),
         {:ok, %{rows: rows}} <-
           Ecto.Adapters.SQL.query(repo, "SELECT name FROM schema_migrations") do
      versions = rows |> Enum.map(&hd/1) |> adoptable_versions()

      if versions != [] do
        Ecto.Adapters.SQL.query!(
          repo,
          "CREATE TABLE IF NOT EXISTS #{source} (version bigint PRIMARY KEY, inserted_at timestamp(0) NOT NULL)"
        )

        for version <- versions do
          Ecto.Adapters.SQL.query!(
            repo,
            "INSERT INTO #{source}(version, inserted_at) VALUES($1, now()) ON CONFLICT (version) DO NOTHING",
            [version]
          )
        end
      end

      {:adopted, versions}
    else
      _ -> :none
    end
  end

  @doc "The Ecto versions whose SQL file is among the given Node migration names."
  def adoptable_versions(
        names,
        migrations_dir \\ Path.join(Application.app_dir(@app, "priv"), "repo/migrations")
      ) do
    applied = MapSet.new(names)

    migrations_dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn file ->
      with [_, version] <- Regex.run(~r/^(\d+)_.*\.exs$/, file),
           [_, sql] <-
             Regex.run(~r/"(\d{3}_[a-z0-9_]+\.sql)"/, File.read!(Path.join(migrations_dir, file))),
           true <- MapSet.member?(applied, sql) do
        [String.to_integer(version)]
      else
        _ -> []
      end
    end)
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Loads the archive export into an empty stories table. Only the repo is
  started: booting the whole application here would bind the web port (taken
  by the running service on a redeploy) and start the delivery loops from a
  one-off command.
  """
  def load_content(file) do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _repo -> Rnews1.Import.load_content([file]) end)
    end
  end

  @doc """
  Runs one `Rnews1.CLI` operation from a release, for cron and other one-off
  callers: `bin/rnews1 eval 'Rnews1.Release.cli(:content, [])'`.

  The whole application starts (the operations need the repo, the HTTP clients
  and the cache) but not the web listener and not the worker loops. The running
  service owns those: a second listener would fight it for the port, and a
  second set of loops would drive the same queues. An exception exits the VM
  non-zero, so a supervisor sees the failure.
  """
  def cli(function, args \\ []) when is_atom(function) and is_list(args) do
    unless Code.ensure_loaded?(Rnews1.CLI) and function_exported?(Rnews1.CLI, function, 1) do
      raise ArgumentError, "Rnews1.CLI has no #{function}/1"
    end

    load_app()
    Application.put_env(@app, :start_workers, false)
    endpoint = Application.get_env(@app, Rnews1Web.Endpoint, [])
    Application.put_env(@app, Rnews1Web.Endpoint, Keyword.put(endpoint, :server, false))
    {:ok, _} = Application.ensure_all_started(@app)
    apply(Rnews1.CLI, function, [args])
    :ok
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)
  defp load_app, do: Application.load(@app)
end
