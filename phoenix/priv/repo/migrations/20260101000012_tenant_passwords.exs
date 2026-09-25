defmodule Rnews1.Repo.Migrations.TenantPasswords do
  @moduledoc """
  Runs priv/repo/sql/012_tenant_passwords.sql verbatim — the same file the Node application
  applied — so the schema is identical by construction and this app can adopt
  a database the Node app built. Every statement in it is idempotent.
  """
  use Ecto.Migration

  @sql Path.join([Application.app_dir(:rnews1, "priv"), "repo", "sql", "012_tenant_passwords.sql"])
  @external_resource @sql

  def up do
    # Postgrex takes one statement per query; the splitter keeps DO blocks whole.
    for statement <- Rnews1.SQLSplit.statements(File.read!(@sql)), do: execute(statement)
  end

  def down, do: :ok
end
