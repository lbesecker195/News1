defmodule Rnews1.Admins do
  @moduledoc "Platform staff: a separate table, a separate cookie, a password."
  alias Rnews1.DB
  alias Rnews1.Util.Password

  def upsert(%{email: email, password: password}) do
    hash = Password.hash(password)

    DB.one(
      """
      INSERT INTO admins(email, password_hash) VALUES($1,$2)
      ON CONFLICT(email) DO UPDATE SET password_hash = EXCLUDED.password_hash, active = true
      RETURNING id, email, (xmax = 0) AS created
      """,
      [email, hash]
    )
  end

  @doc "nil for unknown, deactivated, or wrong password — indistinguishably."
  def authenticate(email, password) do
    admin = DB.one("SELECT * FROM admins WHERE email = $1 AND active", [email])

    case admin do
      %{password_hash: stored} when is_binary(stored) ->
        if Password.verify(password, stored) do
          DB.execute("UPDATE admins SET last_login_at = now() WHERE id = $1", [admin.id])
          %{id: admin.id, email: admin.email}
        end

      _ ->
        Password.no_user_verify()
        nil
    end
  end

  def create_session(hash, admin_id) do
    DB.execute("INSERT INTO admin_sessions(hash, admin_id, expires_at) VALUES($1,$2,now() + interval '12 hours')", [
      hash,
      admin_id
    ])
  end

  def find_by_session(hash) do
    DB.one(
      """
      SELECT a.id, a.email FROM admin_sessions s
      JOIN admins a ON a.id = s.admin_id
      WHERE s.hash = $1 AND s.expires_at > now() AND a.active
      """,
      [hash]
    )
  end

  def delete_session(hash), do: DB.execute("DELETE FROM admin_sessions WHERE hash = $1", [hash])
  def prune_sessions, do: DB.execute("DELETE FROM admin_sessions WHERE expires_at <= now()")
end
