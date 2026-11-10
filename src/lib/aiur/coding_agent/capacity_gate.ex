defmodule Aiur.CodingAgent.CapacityGate do
  @moduledoc """
  Applies the capacity policy (`Aiur.Capacity.Policy`, #7881 PCP-4) to the
  candidates a dispatch can choose from.

  Headroom selection (`Aiur.CodingAgent.HeadroomDispatch`), the `priority` and
  `balance` chain (`Aiur.CodingAgent.Routing.FloorChain`) and the fleet provider
  gate all call this module, so the three agree on which sources may take work.

  Each candidate gets one entry, in input order:

    * a candidate the usage ledger marks limited is `:limited`. It stays in the
      allowed list so the ranker still shows it as exhausted, but it does not
      count as an allowed source when the policy decides whether a last-resort
      source may be used, nor does it keep a route open in `allowed_routes/2`;
    * the usage floor (`Aiur.CodingAgent.UsageFloorGate`, per-backend floor and
      spent prepaid balance) holds with `:floor` or `:balance_exhausted`;
    * every other candidate is decided by `Aiur.Capacity.Policy`: hard limits,
      reserve, last resort and `serves`.

  A pin (`pinned: true`) obeys hard limits and the reserve only: it skips the
  floor and the limited check, as a pin did before the policy.

  With no `capacity` config every candidate today's gates allow is allowed, so
  dispatch is unchanged.
  """

  require Logger

  alias Aiur.Accounts.{Headroom, UsageFloor}
  alias Aiur.Capacity.{LedgerStore, Policy}
  alias Aiur.CodingAgent.{HeadroomDispatch, UsageFloorGate}
  alias Aiur.Config.CapacityPolicy
  alias Aiur.Machine.Settings

  @typedoc "One candidate's verdict. `reason` is `nil` for an ordinary allowed candidate."
  @type entry :: %{candidate: map(), verdict: :allow | :hold | :defer, reason: atom() | nil, detail: String.t() | nil}

  @type result :: %{allowed: [map()], floor_held: [UsageFloorGate.held_entry()], entries: [entry()]}

  @doc """
  Evaluate `candidates` with their `readings` (keyed as `HeadroomDispatch.readings/2` returns them).

  `allowed` keeps input order and includes `:limited` candidates (see the module
  docs). `floor_held` is in `UsageFloorGate`'s shape so callers keep recording
  and rendering floor holds as before.

  Options: `:pinned`, `:capacity_policy` (the effective policy map),
  `:capacity_holds` (default: the open holds in the `:ledger_store`, see
  `store/1`) and `:capacity_spend` (passed to the policy as `:holds` and
  `:spend`), plus the floor options `UsageFloorGate.split_candidates/3` reads.
  """
  @spec evaluate([map()], map(), keyword()) :: result()
  def evaluate(candidates, readings, opts \\ []) when is_list(candidates) and is_map(readings) do
    pinned? = Keyword.get(opts, :pinned, false)
    policy = Keyword.get_lazy(opts, :capacity_policy, &policy/0)

    {_open, floor_held} = if pinned?, do: {candidates, []}, else: UsageFloorGate.split_candidates(candidates, readings, opts)
    # Two routes on one backend expand to the same account, so entries are keyed by position.
    floored = Map.new(floor_held, &{Headroom.key(&1.candidate), &1.held})
    indexed = Enum.with_index(candidates)

    {decidable, settled} =
      Enum.reduce(indexed, {[], %{}}, fn {candidate, index}, {decidable, settled} ->
        key = Headroom.key(candidate)

        cond do
          Map.has_key?(floored, key) -> {decidable, Map.put(settled, index, floor_entry(candidate, floored[key]))}
          not pinned? and limited?(readings, key) -> {decidable, Map.put(settled, index, entry(candidate, :allow, :limited, "usage-limited"))}
          true -> {[{candidate, index} | decidable], settled}
        end
      end)

    decided =
      decidable
      |> Enum.reverse()
      |> Enum.map(fn {candidate, index} -> policy_candidate(candidate, index, readings) end)
      |> Policy.decide(policy, holds: Keyword.get_lazy(opts, :capacity_holds, fn -> LedgerStore.policy_holds(candidates, readings, store(opts)) end), spend: Keyword.get(opts, :capacity_spend, %{}))
      |> Map.new(fn {input, verdict} -> {input.index, policy_entry(input, verdict, policy)} end)

    entries = Enum.map(indexed, fn {_candidate, index} -> Map.get(settled, index) || Map.fetch!(decided, index) end)
    %{allowed: for(%{verdict: :allow, candidate: c} <- entries, do: c), floor_held: floor_held, entries: entries}
  end

  @doc """
  The routes with at least one allowed candidate, in input order. Records floor
  holds and recoveries (alerts) when `record: true`, which claim-time selection
  passes and read-only surfaces do not.
  """
  @spec allowed_routes([String.t()], keyword()) :: [String.t()]
  def allowed_routes(routes, opts \\ []) when is_list(routes) do
    candidates = UsageFloorGate.candidates(routes, opts)
    %{entries: entries, floor_held: held} = evaluate(candidates, HeadroomDispatch.readings(candidates, opts), opts)

    if Keyword.get(opts, :record, false), do: UsageFloorGate.record(held, Enum.map(candidates, &UsageFloorGate.label/1), opts)

    # A limited candidate cannot take work now, so it does not keep its route open.
    allowed_routes = for %{verdict: :allow, reason: reason, candidate: c} <- entries, reason != :limited, into: MapSet.new(), do: c.route
    Enum.filter(routes, &MapSet.member?(allowed_routes, &1))
  end

  @doc """
  Claims the reservation hold for an issue dispatch just selected a source for
  (#7890): re-checks the reserve and records the hold in one store call.
  Returns `:ok` or `{:hold, reason}`.
  """
  @spec claim(map(), keyword()) :: :ok | {:hold, atom()}
  def claim(issue, opts \\ []), do: LedgerStore.claim(issue, server: store(opts), capacity_policy: Keyword.get_lazy(opts, :capacity_policy, &policy/0))

  @doc "Hands the claimed hold to the agent the dispatch started, or releases it when none started."
  @spec started(term(), map() | nil, keyword()) :: :ok
  def started(ticket, %{pid: pid}, opts) when is_pid(pid), do: LedgerStore.attach(ticket, pid, store(opts))
  def started(ticket, _no_entry, opts), do: LedgerStore.release(ticket, store(opts))

  @doc "Rebuilds reservation holds from running entries (`%{issue:, pid:, started_at:}`) after a handoff."
  @spec rebuild_holds([map()], keyword()) :: :ok
  def rebuild_holds(entries, opts \\ []), do: LedgerStore.rebuild(entries, server: store(opts), capacity_policy: Keyword.get_lazy(opts, :capacity_policy, &policy/0))

  # Tests set `:capacity_ledger_store` to nil (no holds) and pass `:ledger_store` to use their own.
  @doc false
  @spec store(keyword()) :: GenServer.server() | nil
  def store(opts), do: Keyword.get_lazy(opts, :ledger_store, fn -> Application.get_env(:aiur, :capacity_ledger_store, LedgerStore) end)

  @doc """
  Why the chosen candidate was chosen: `:pinned`, `:last_resort_used`,
  `:only_allowed` (no other source was allowed) or `:preferred`.
  """
  @spec chosen_reason(map(), [entry()], boolean()) :: atom()
  def chosen_reason(_candidate, _entries, true), do: :pinned

  def chosen_reason(candidate, entries, false) do
    key = Headroom.key(candidate)

    cond do
      Enum.any?(entries, &(Headroom.key(&1.candidate) == key and &1.reason == :last_resort_used)) -> :last_resort_used
      Enum.count(entries, &(&1.verdict == :allow and &1.reason != :limited)) == 1 -> :only_allowed
      true -> :preferred
    end
  end

  @doc """
  The entries dispatch could not choose, split into floor holds (which carry
  `held` in `UsageFloorGate`'s shape) and every other hold or deferral.
  """
  @spec unchosen([entry()]) :: {[entry()], [entry()]}
  def unchosen(entries), do: entries |> Enum.reject(&(&1.verdict == :allow)) |> Enum.split_with(&Map.has_key?(&1, :held))

  @doc "The `; deferred …` / `; held …` summary fragment for non-floor entries, or `\"\"`."
  @spec summary([entry()]) :: String.t()
  def summary([]), do: ""
  def summary(entries), do: "; " <> Enum.map_join(entries, ", ", &"#{Headroom.name(&1.candidate)} #{&1.verdict}: #{&1.reason} (#{&1.detail})")

  @doc "A scored candidate's record row with its verdict and reason (`nil` unless limited or last resort)."
  @spec with_verdict(map(), map(), [entry()]) :: map()
  def with_verdict(view, candidate, entries) do
    reason = Enum.find_value(entries, &(&1.candidate == candidate && &1.reason))
    Map.merge(view, %{verdict: :allow, reason: reason})
  end

  @doc "Record rows for floor holds (with their window) and for other held or deferred entries."
  @spec views([entry()], [entry()]) :: [map()]
  def views(floor, other), do: Enum.map(floor, &Map.merge(entry_view(&1), UsageFloorGate.held_view(&1))) ++ Enum.map(other, &entry_view/1)

  defp entry_view(%{candidate: candidate} = entry) do
    %{
      name: Headroom.name(candidate),
      backend: candidate.backend,
      account: candidate.account,
      route: candidate.route,
      status: entry.verdict,
      verdict: entry.verdict,
      reason: entry.reason,
      detail: entry.detail
    }
  end

  # The policy keys a source by backend and needs the reading; the original
  # candidate rides along so the verdict maps back to it. An implicit account
  # is `default`, as the reserve's `accounts:` list names it.
  defp policy_candidate(candidate, index, readings) do
    %{route: candidate.backend, account: candidate.account || "default", reading: Map.get(readings, Headroom.key(candidate)), candidate: candidate, index: index}
  end

  defp policy_entry(%{candidate: candidate}, :allow, policy) do
    if last_resort?(policy, candidate.backend),
      do: entry(candidate, :allow, :last_resort_used, "no other source is allowed"),
      else: entry(candidate, :allow, nil, nil)
  end

  defp policy_entry(%{candidate: candidate}, {:defer, :last_resort}, _policy),
    do: entry(candidate, :defer, :last_resort, "deferred while another source is allowed")

  defp policy_entry(%{candidate: candidate} = input, {:hold, reason}, policy),
    do: entry(candidate, :hold, reason, hold_detail(reason, input, policy))

  defp floor_entry(candidate, held) do
    reason = if held.window == "credits" and held.remaining_percent <= 0, do: :balance_exhausted, else: :floor
    candidate |> entry(:hold, reason, UsageFloor.held_line(held)) |> Map.put(:held, held)
  end

  defp entry(candidate, verdict, reason, detail), do: %{candidate: candidate, verdict: verdict, reason: reason, detail: detail}

  defp hold_detail(:reserve, %{reading: reading, candidate: candidate}, policy) do
    "reading #{round(UsageFloor.remaining_percent(reading))}% left, reserve #{reserve_percent(policy, candidate.backend)}%"
  end

  defp hold_detail(:reading_unknown, _input, _policy), do: "no fresh reading on a reserved account"
  defp hold_detail(:spend_unknown, _input, _policy), do: "spend unknown while a limit is set"
  defp hold_detail(:not_served, _input, _policy), do: "source does not serve coding work"
  defp hold_detail(limit, _input, _policy), do: "#{limit |> to_string() |> String.replace("_", " ")} reached"

  defp source(policy, backend), do: Map.get(Map.get(policy, :sources) || %{}, backend) || %{}
  defp last_resort?(policy, backend), do: Map.get(source(policy, backend), :last_resort) == true
  defp reserve_percent(policy, backend), do: get_in(source(policy, backend), [:reserve, :percent])

  defp limited?(readings, key), do: match?(%{limited: true}, Map.get(readings, key))

  @doc """
  The effective capacity policy. A project-layer error (say the machine reserve
  was raised above the project value) falls back to the machine layer alone,
  which is never looser, so reserves fail closed. Only an unreadable machine
  file allows every route.
  """
  @spec policy() :: map()
  def policy do
    case CapacityPolicy.effective() do
      {:ok, policy} ->
        :persistent_term.erase({__MODULE__, :last_error})
        policy

      {:error, reason} ->
        warn_once(reason)

        with {:ok, machine} <- Settings.get(),
             {:ok, policy} <- CapacityPolicy.effective(machine.capacity, nil) do
          policy
        else
          _unreadable -> %{}
        end
    end
  end

  # The gate runs several times per poll; log only when the error changes.
  defp warn_once(reason) do
    if :persistent_term.get({__MODULE__, :last_error}, nil) != reason do
      :persistent_term.put({__MODULE__, :last_error}, reason)
      Logger.warning("capacity policy unreadable, using the machine layer alone: #{inspect(reason)}")
    end
  end
end
