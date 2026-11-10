defmodule Aiur.Capacity.LedgerStore do
  @moduledoc """
  The daemon's one `Aiur.Capacity.Ledger` (#7890), shared by every project's
  dispatcher because accounts are machine-wide.

  `Aiur.CodingAgent.CapacityGate` reads `policy_holds/3` before it decides, and
  dispatch calls `hold/2` as soon as it selects a source, so the next claim in
  the same poll interval sees the first. A teardown releases the hold; handoff
  adoption rebuilds holds from the adopted agents, so nothing is written to disk.

  Only `:window` holds on subscription accounts are recorded here: they are what
  the reserve reads. Every call is a no-op when the store is not running.
  """

  use Agent

  alias Aiur.Accounts.{Headroom, UsageFloor}
  alias Aiur.Capacity.Ledger
  alias Aiur.CodingAgent.CapacityGate

  # ponytail: a hold is one agent-hour of burn, folded at the next fresh reading; size by run length if that undershoots.
  @expected_hours 1

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []), do: Agent.start_link(&Ledger.new/0, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  The open holds in `Aiur.Capacity.Policy`'s `:holds` shape. Folds each
  candidate's reading first, so a hold older than its account's reading no
  longer subtracts. An unknown estimate is `estimate_percent: nil`.
  """
  @spec policy_holds([map()], map(), GenServer.server()) :: [map()]
  def policy_holds(candidates, readings, server \\ __MODULE__) do
    call(server, [], fn ledger ->
      ledger = Enum.reduce(candidates, ledger, &fold(&2, &1, Map.get(readings, Headroom.key(&1))))
      holds = for %{kind: :window, folded_at: nil} = h <- Map.values(ledger.holds), do: %{route: h.backend, account: h.account, estimate_percent: number(h.estimate)}
      {holds, ledger}
    end)
  end

  @doc "Records the hold for an issue dispatch just selected a source for."
  @spec hold(map(), keyword()) :: :ok
  def hold(issue, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    policy = Keyword.get_lazy(opts, :capacity_policy, &CapacityGate.policy/0)
    call(server, :ok, &{:ok, record(&1, issue, now, policy)})
  end

  @doc "Closes a stopped agent's hold."
  @spec release(term(), GenServer.server()) :: :ok
  def release(ticket, server \\ __MODULE__), do: call(server, :ok, &{:ok, Ledger.release(&1, ticket)})

  @doc "Rebuilds holds for running entries (`%{issue:, started_at:}`) after an adoption."
  @spec rebuild([map()], keyword()) :: :ok
  def rebuild(entries, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    policy = Keyword.get_lazy(opts, :capacity_policy, &CapacityGate.policy/0)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    # A restored start time that is not a DateTime counts from now, which only overstates the hold.
    started = &if(match?(%DateTime{}, &1[:started_at]), do: &1.started_at, else: now)
    call(server, :ok, fn ledger -> {:ok, Enum.reduce(entries, ledger, &record(&2, &1[:issue], started.(&1), policy))} end)
  end

  @doc false
  @spec ledger(GenServer.server()) :: Ledger.t() | nil
  def ledger(server \\ __MODULE__), do: call(server, nil, &{&1, &1})

  defp record(ledger, %{id: id, selected_backend: backend} = issue, %DateTime{} = at, policy) when is_binary(backend) do
    account = Map.get(issue, :selected_account) || "default"

    if subscription?(policy, backend) do
      {estimate, rate} = Ledger.window_estimate(Ledger.learned_burn(ledger, backend, account), Map.get(policy, :default_burn_percent_per_hour), @expected_hours)
      Ledger.hold(ledger, %{ticket: id, backend: backend, account: account, kind: :window, estimate: estimate, rate: rate, created_at: at})
    else
      ledger
    end
  end

  defp record(ledger, _issue, _at, _policy), do: ledger

  defp fold(ledger, candidate, %{observed_at: %DateTime{} = at} = reading) do
    key = {candidate.backend, candidate.account || "default"}
    previous = Map.get(ledger.readings, key)

    case UsageFloor.remaining_percent(reading) do
      remaining when is_number(remaining) and (previous == nil or previous.observed_at != at) ->
        Ledger.observe_reading(ledger, elem(key, 0), elem(key, 1), %{used_percent: 100 - remaining, observed_at: at})

      _unchanged ->
        ledger
    end
  end

  defp fold(ledger, _candidate, _reading), do: ledger

  defp subscription?(policy, backend), do: get_in(policy, [:sources, backend, :billing]) == "subscription"

  defp number(value) when is_number(value), do: value
  defp number(_unknown), do: nil

  defp call(server, default, fun) do
    if GenServer.whereis(server), do: Agent.get_and_update(server, fun), else: default
  catch
    :exit, _reason -> default
  end
end
