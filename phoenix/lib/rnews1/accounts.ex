defmodule Rnews1.Accounts do
  @moduledoc """
  Tenants and how they sign in: by emailed link, or by an optional password.
  Signing in and signing up are the same act — the tenant row is created on
  first sight of an email address, and the account only becomes real once the
  link is followed.
  """
  alias Rnews1.DB
  alias Rnews1.Sites
  alias Rnews1.Util.Password

  @session_days 14
  def session_days, do: @session_days

  @doc "Creates (or finds) the tenant, records a login token, queues the mail."
  def create_login(%{email: email, token_hash: token_hash, url: url}) do
    DB.transaction(fn ->
      tenant_id = Sites.ensure_tenant(%{email: email})

      DB.execute(
        "INSERT INTO login_tokens(hash,tenant_id,expires_at) VALUES($1,$2,now()+interval '20 minutes')",
        [token_hash, tenant_id]
      )

      DB.execute(
        """
        INSERT INTO outbox(tenant_id,to_email,kind,payload,expires_at)
        VALUES($1,$2,'login',$3,now()+interval '20 minutes')
        """,
        [tenant_id, email, %{url: url}]
      )

      tenant_id
    end)
  end

  @doc "The DELETE ... RETURNING is what makes the link single-use."
  def consume_login_and_create_session(%{login_hash: login_hash, session_hash: session_hash}) do
    DB.transaction(fn ->
      case DB.one("DELETE FROM login_tokens WHERE hash=$1 AND expires_at>now() RETURNING tenant_id", [login_hash]) do
        nil ->
          nil

        %{tenant_id: tenant_id} ->
          DB.execute(
            "INSERT INTO sessions(hash,tenant_id,expires_at) VALUES($1,$2,now()+interval '14 days')",
            [session_hash, tenant_id]
          )

          tenant_id
      end
    end)
  end

  def find_tenant_by_session(session_hash) do
    DB.one(
      "SELECT t.* FROM sessions s JOIN tenants t ON t.id=s.tenant_id WHERE s.hash=$1 AND s.expires_at>now()",
      [session_hash]
    )
  end

  def delete_session(session_hash), do: DB.execute("DELETE FROM sessions WHERE hash=$1", [session_hash])

  @doc "A session for a tenant who proved who they are some other way — by password."
  def create_session_for(tenant_id, session_hash) do
    DB.execute(
      "INSERT INTO sessions(hash, tenant_id, expires_at) VALUES($1, $2, now() + ($3 || ' days')::interval)",
      [session_hash, tenant_id, to_string(@session_days)]
    )
  end

  @doc """
  The tenant, or nil for an unknown address, an account with no password, or
  a wrong password — never saying which, and never faster for one than another.
  """
  def authenticate_tenant(email, password) do
    tenant = DB.one("SELECT * FROM tenants WHERE owner_email = $1", [email])

    case tenant do
      %{password_hash: stored} when is_binary(stored) ->
        if Password.verify(password, stored), do: tenant, else: nil

      _ ->
        Password.no_user_verify()
        nil
    end
  end

  def has_password(tenant_id) do
    DB.one("SELECT password_hash IS NOT NULL AS set, password_set_at FROM tenants WHERE id = $1", [tenant_id]) ||
      %{set: false, password_set_at: nil}
  end

  @doc """
  Sets or clears the password, and ends every other session as it goes. The
  session doing the changing survives.
  """
  def set_password(tenant_id, plain, keep_session_hash \\ nil) do
    password_hash = if is_nil(plain), do: nil, else: Password.hash(plain)

    DB.transaction(fn ->
      DB.execute(
        """
        UPDATE tenants
        SET password_hash = $2,
            password_set_at = CASE WHEN $2::text IS NULL THEN NULL ELSE now() END
        WHERE id = $1
        """,
        [tenant_id, password_hash]
      )

      DB.execute("DELETE FROM sessions WHERE tenant_id = $1 AND hash <> COALESCE($2, '')", [
        tenant_id,
        keep_session_hash
      ])

      :ok
    end)
  end

  def find_tenant(id), do: DB.one("SELECT * FROM tenants WHERE id = $1", [id])
  def find_tenant_by_email(email), do: DB.one("SELECT * FROM tenants WHERE owner_email = $1", [email])
end
