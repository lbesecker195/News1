defmodule Rnews1Web.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint Rnews1Web.Endpoint
      import Plug.Conn
      import Phoenix.ConnTest
      import Rnews1Web.ConnCase
      import Rnews1.Fixtures
      alias Rnews1.DB
    end
  end

  setup tags do
    Rnews1.DataCase.setup_sandbox(tags)
    Rnews1Web.RateLimit.reset_all()
    {:ok, conn: %{Phoenix.ConnTest.build_conn() | host: "rnews1.test"}}
  end

  @doc "A request as it arrives on a given host."
  def on_host(conn, host), do: %{conn | host: host}

  @doc "A signed-in API request: session cookie and the CSRF origin."
  def as_tenant(conn, secret) do
    conn
    |> Plug.Test.put_req_cookie("session", secret)
    |> Plug.Conn.put_req_header("origin", "https://rnews1.test")
  end

  def with_origin(conn), do: Plug.Conn.put_req_header(conn, "origin", "https://rnews1.test")

  def body_of(conn), do: conn.resp_body
  def json_of(conn), do: Jason.decode!(conn.resp_body)
  def location(conn), do: conn |> Plug.Conn.get_resp_header("location") |> List.first()
  def header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()
end
