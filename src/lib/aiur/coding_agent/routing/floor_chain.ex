defmodule Aiur.CodingAgent.Routing.FloorChain do
  @moduledoc """
  The `priority`/`balance` route chain with the remaining-usage floor (#7504).

  `agent.usage_floor_percent` holds a route whose freshest reading is at or
  below the floor, so the chain skips it and takes the next allowed entry in
  `agent.priority` — the same fall-through an exhausted route already gets. A
  routed default that is floored falls through instead of dispatching into it,
  and when nothing is left the hold names every route it considered.

  `Aiur.CodingAgent.Routing` owns the route list and the pin/routing reads; this
  module owns the decision over that list, so the floor logic lives in one place
  and the routing module keeps its size. The floor is one rule of the capacity
  policy (`Aiur.CodingAgent.CapacityGate`, #7889): limits, the reserve and last
  resort hold or defer a route the same way.
  """

  alias Aiur.CodingAgent.CapacityGate
  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.ModelAvailability

  @typedoc "The route decision for one claim."
  @type decision :: {:ok, Issue.t()} | {:all_limited, [String.t()]}

  @typedoc "The caller's route list for this claim, in `agent.priority` order."
  @type routes_fun :: (keyword() -> [String.t()])

  @typedoc "Applies a chosen route to the issue."
  @type select_fun :: (Issue.t(), String.t() -> Issue.t())

  @doc """
  Decide a claim whose routed default is `backend`.

  A routed default is a default, not a pin: when the floor holds it the chain
  falls through to the next allowed route, and when nothing is left the hold
  names both the floored default and the routes it fell through to.
  """
  @spec routed(Issue.t(), keyword(), String.t(), routes_fun(), select_fun()) :: decision()
  def routed(issue, opts, backend, eligible_routes, select_route) do
    cond do
      not ModelAvailability.available?(backend, opts) -> {:all_limited, [backend]}
      backend in allowed(Enum.uniq([backend | eligible_routes.(opts)]), opts) -> {:ok, issue}
      true -> fallback(issue, opts, backend, eligible_routes, select_route)
    end
  end

  @doc """
  Decide a claim with no routed backend: walk `agent.priority` and take the
  first route the floor allows.
  """
  @spec chain(Issue.t(), keyword(), routes_fun(), select_fun()) :: decision()
  def chain(issue, opts, eligible_routes, select_route) do
    candidates = eligible_routes.(opts)
    allowed = allowed(candidates, opts)

    cond do
      candidates == [] -> default_backend(issue, opts)
      allowed == [] -> {:all_limited, candidates}
      true -> first_available(issue, opts, allowed, {:all_limited, candidates}, select_route)
    end
  end

  defp fallback(issue, opts, floored_backend, eligible_routes, select_route) do
    candidates = eligible_routes.(opts)
    allowed = allowed(candidates, opts)
    unavailable = {:all_limited, Enum.uniq([floored_backend | candidates])}

    case {candidates, allowed} do
      {[], _none} -> {:all_limited, [floored_backend]}
      {_, []} -> unavailable
      {_, allowed} -> first_available(issue, opts, allowed, unavailable, select_route)
    end
  end

  defp first_available(issue, opts, allowed, unavailable, select_route) do
    case ModelAvailability.first_available(allowed, opts) do
      nil -> unavailable
      route -> {:ok, select_route.(issue, route)}
    end
  end

  # No route list at all: the claim falls back to `agent.kind`, which the floor
  # can hold just as it holds a configured route.
  defp default_backend(issue, opts) do
    backend = Keyword.get_lazy(opts, :default_backend, &Config.agent_kind/0)

    cond do
      not ModelAvailability.available?(backend, opts) -> {:all_limited, [backend]}
      allowed([backend], opts) == [] -> {:all_limited, [backend]}
      true -> {:ok, issue}
    end
  end

  # Claim-time evaluation records floor holds and recoveries, as the floor did.
  defp allowed(routes, opts), do: CapacityGate.allowed_routes(routes, Keyword.put(opts, :record, true))
end
