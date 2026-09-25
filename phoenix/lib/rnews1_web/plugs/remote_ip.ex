defmodule Rnews1Web.Plugs.RemoteIp do
  @moduledoc """
  The client's address behind a known number of proxies.

  The chain is the socket peer followed by X-Forwarded-For read right to
  left; the first address after the trusted hops is the client. Behind Caddy
  alone that is one hop; behind Caddy and the nginx cache, two. Reading the
  leftmost entry instead would let any client name its own address and step
  around every per-IP limit.
  """
  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    hops = trusted_hops()

    if hops == 0 do
      conn
    else
      forwarded =
        conn
        |> Plug.Conn.get_req_header("x-forwarded-for")
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.reverse()

      case Enum.at(forwarded, hops - 1) do
        nil ->
          conn

        address ->
          case :inet.parse_address(String.to_charlist(address)) do
            {:ok, ip} -> %{conn | remote_ip: ip}
            _ -> conn
          end
      end
    end
  end

  def trusted_hops do
    case Rnews1.Env.get(:trust_proxy, false) do
      true -> Rnews1.Env.get(:trust_proxy_hops, 1)
      _ -> 0
    end
  end
end
