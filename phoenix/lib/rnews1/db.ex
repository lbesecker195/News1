defmodule Rnews1.DB do
  @moduledoc """
  Hand-written SQL, as the application was written.

  The queries are the tested logic — `FOR UPDATE SKIP LOCKED` queues, jsonb
  targeting, partial-index upserts, window functions — and Postgres speaks the
  same `$1` placeholders to Postgrex that it spoke to node-postgres, so they
  come across unchanged. Ecto still owns migrations, the connection pool and
  the test sandbox; this module is the few lines between them and a map per
  row.

  Inside `transaction/1` every query runs on the transaction's connection —
  Ecto binds it to the process — so there is no client handle to pass around.
  """

  alias Rnews1.Repo

  @doc "Runs a query; returns `{rows, count}` where rows are maps with atom keys."
  def query(sql, params \\ []) do
    %{rows: rows, columns: columns, num_rows: count} = Repo.query!(sql, params)

    {to_maps(rows, columns), count}
  end

  @doc "Every row."
  def all(sql, params \\ []) do
    {rows, _} = query(sql, params)
    rows
  end

  @doc "The first row, or nil."
  def one(sql, params \\ []) do
    sql |> all(params) |> List.first()
  end

  @doc "The single value of the single row, or nil."
  def value(sql, params \\ []) do
    case Repo.query!(sql, params) do
      %{rows: [[value | _] | _]} -> value
      _ -> nil
    end
  end

  @doc "Rows affected."
  def execute(sql, params \\ []) do
    %{num_rows: count} = Repo.query!(sql, params)
    count
  end

  @doc """
  A transaction. The function's return value comes back plainly; raising
  inside rolls back and re-raises, which is what the callers expect.
  """
  def transaction(fun) when is_function(fun, 0) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, reason} -> raise "transaction failed: #{inspect(reason)}"
    end
  end

  @doc "Rolls the enclosing transaction back with a value; see Repo.rollback/1."
  def rollback(value), do: Repo.rollback(value)

  @doc "`YYYY-MM-DD` or a Date to a Date, for `$n::date` parameters."
  def date(%Date{} = date), do: date
  def date(nil), do: nil
  def date(string) when is_binary(string), do: Date.from_iso8601!(string)

  @doc "The date as its slug."
  def slug(%Date{} = date), do: Date.to_iso8601(date)
  def slug(nil), do: nil
  def slug(string) when is_binary(string), do: string

  defp to_maps(rows, columns) do
    keys = Enum.map(columns, &String.to_atom/1)

    Enum.map(rows, fn row -> keys |> Enum.zip(row) |> Map.new() end)
  end
end
