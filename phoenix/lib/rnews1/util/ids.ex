defmodule Rnews1.Util.Ids do
  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  def uuid?(value) when is_binary(value), do: Regex.match?(@uuid, value)
  def uuid?(_), do: false

  @doc "token/0 is 32 random bytes as base64url, which is always 43 characters."
  def login_token?(value) when is_binary(value), do: Regex.match?(~r/^[A-Za-z0-9_-]{43}$/, value)
  def login_token?(_), do: false

  @doc "32 bytes of entropy, URL-safe, 43 characters."
  def token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  @doc """
  Used for two unrelated jobs: keying topics by their query, and storing
  session/login secrets so a database leak does not hand out live sessions.
  """
  def hash(value), do: :crypto.hash(:sha256, to_string(value)) |> Base.encode16(case: :lower)
end
