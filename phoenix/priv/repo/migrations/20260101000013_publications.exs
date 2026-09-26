defmodule Rnews1.Repo.Migrations.Publications do
  @moduledoc """
  Runs priv/repo/sql/013_publications.sql verbatim, the same way every other
  migration here does, so the schema stays identical by construction to the one
  the SQL files describe. Every statement in it is idempotent.
  """
  use Ecto.Migration

  @sql Path.join([Application.app_dir(:rnews1, "priv"), "repo", "sql", "013_publications.sql"])
  @external_resource @sql

  def up do
    # Postgrex takes one statement per query; the splitter keeps DO blocks whole.
    for statement <- Rnews1.SQLSplit.statements(File.read!(@sql)), do: execute(statement)
  end

  def down, do: :ok
end
