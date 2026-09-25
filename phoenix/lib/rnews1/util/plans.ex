defmodule Rnews1.Util.Plans do
  @moduledoc """
  What a plan buys.

    standard    $25/month — a branded subdomain on the platform domain, the
                feed, the embed with our mark on it.
    enterprise  a hostname the customer owns, and the mark comes off.
  """
  @plans ~w(standard enterprise)

  def plans, do: @plans

  def plan_of(tenant) do
    plan = tenant && Map.get(tenant, :plan)
    if plan in @plans, do: plan, else: "standard"
  end

  def enterprise?(tenant), do: plan_of(tenant) == "enterprise"

  @doc "Comped: entitled with no subscription behind it; never sent to checkout."
  def comped?(tenant), do: not is_nil(tenant && Map.get(tenant, :comped_reason))

  def entitlements(tenant) do
    plan = plan_of(tenant)
    enterprise = plan == "enterprise"

    %{
      plan: plan,
      customDomain: enterprise,
      branding: not enterprise,
      comped: comped?(tenant),
      comped_reason: tenant && Map.get(tenant, :comped_reason)
    }
  end
end
