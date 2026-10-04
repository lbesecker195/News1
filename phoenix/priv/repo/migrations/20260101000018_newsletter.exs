defmodule Rnews1.Repo.Migrations.Newsletter do
  @moduledoc """
  Runs priv/repo/sql/018_newsletter.sql verbatim, the same way every other
  migration here does. Every statement in it is idempotent.
  """
  use Ecto.Migration

  @sql Path.join([Application.app_dir(:rnews1, "priv"), "repo", "sql", "018_newsletter.sql"])
  @external_resource @sql

  def up do
    for statement <- Rnews1.SQLSplit.statements(File.read!(@sql)), do: execute(statement)
  end

  def down, do: :ok
end
