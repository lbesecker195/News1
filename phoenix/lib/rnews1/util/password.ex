defmodule Rnews1.Util.Password do
  @moduledoc """
  Argon2id, via argon2_elixir.

  OTP has no scrypt, so the Node application's `scrypt$…` hashes cannot be
  verified here; the two that existed are re-set. Eight characters minimum
  following NIST 800-63B — what stops guessing is the rate limit on the
  sign-in route, not a composition rule.
  """
  @min_length 8

  def min_length, do: @min_length

  def hash(plain) when is_binary(plain) and byte_size(plain) >= @min_length do
    Argon2.hash_pwd_salt(plain)
  end

  def hash(_), do: raise(ArgumentError, "A password must be at least #{@min_length} characters.")

  @doc "False rather than raising on a malformed stored value."
  def verify(plain, stored) when is_binary(plain) and is_binary(stored) do
    Argon2.verify_pass(plain, stored)
  rescue
    _ -> false
  end

  def verify(_, _), do: false

  @doc "Burns the same time as a real check, so a missing account answers no slower."
  def no_user_verify, do: Argon2.no_user_verify()
end
