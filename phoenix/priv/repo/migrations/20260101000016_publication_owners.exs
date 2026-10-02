defmodule Rnews1.Repo.Migrations.PublicationOwners do
  @moduledoc """
  Runs priv/repo/sql/016_publication_owners.sql verbatim, the same way every
  other migration here does. Every statement in it is idempotent.
  """
  use Ecto.Migration

  @sql Path.join([Application.app_dir(:rnews1, "priv"), "repo", "sql", "016_publication_owners.sql"])
  @external_resource @sql

  def up do
    for statement <- Rnews1.SQLSplit.statements(File.read!(@sql)), do: execute(statement)
  end

  def down, do: :ok
end
