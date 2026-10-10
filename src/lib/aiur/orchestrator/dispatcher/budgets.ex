defmodule Aiur.Orchestrator.Dispatcher.Budgets do
  @moduledoc """
  Redispatch admission and the thrash and lifetime dispatch budgets.
  """

  require Logger

  alias Aiur.CodingAgent
  alias Aiur.Config
  alias Aiur.DispatchBudgetStore
  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.Dispatcher.BudgetTrip
  alias Aiur.Orchestrator.Dispatcher.Launch
  alias Aiur.Orchestrator.State

  @doc false
  @spec redispatch_ready?(State.t(), Issue.t(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def redispatch_ready?(%State{} = state, %Issue{} = issue, preferred_worker_host, opts \\ []) do
    now_ms = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))

    with {:ok, selected_issue} <- redispatch_backend(issue),
         :ok <- known_redispatch_backend(selected_issue),
         :ok <- redispatch_thrash_budget(state, selected_issue.id, now_ms),
         :ok <- redispatch_worker_slot(state, selected_issue, preferred_worker_host) do
      :ok
    else
      {:all_limited, candidates} -> {:error, {:all_limited, candidates}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec admit_redispatch(State.t(), Issue.t(), String.t() | nil, keyword()) ::
          {:ok, State.t()} | {:error, term(), State.t()}
  def admit_redispatch(%State{} = state, %Issue{} = issue, preferred_worker_host, opts \\ []) do
    now_ms = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))

    with {:ok, selected_issue} <- redispatch_backend(issue),
         :ok <- known_redispatch_backend(selected_issue),
         {:ok, state} <- admit_redispatch_thrash_budget(state, selected_issue, now_ms, opts),
         :ok <- redispatch_worker_slot(state, selected_issue, preferred_worker_host) do
      {:ok, state}
    else
      {:all_limited, candidates} -> {:error, {:all_limited, candidates}, state}
      {:error, reason, %State{} = rejected_state} -> {:error, reason, rejected_state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp redispatch_backend(issue), do: CodingAgent.select_for_dispatch(issue)

  defp known_redispatch_backend(issue) do
    backend = CodingAgent.backend_for(issue)

    if backend in CodingAgent.known_backends(),
      do: :ok,
      else: {:error, {:unknown_backend, backend}}
  end

  defp redispatch_thrash_budget(state, issue_id, now_ms) do
    previous = Map.get(thrash_budget(state), issue_id)
    entry = next_thrash_budget_entry(state, issue_id, now_ms)

    if active_trip?(previous, now_ms) or not is_nil(budget_trip_reason(entry)),
      do: {:error, :thrash_circuit_open},
      else: :ok
  end

  defp admit_redispatch_thrash_budget(state, issue, now_ms, opts) do
    previous = Map.get(thrash_budget(state), issue.id)
    trip = Keyword.get(opts, :trip_fun, &BudgetTrip.trip_thrash_breaker/2)

    if active_trip?(previous, now_ms) do
      {:error, :thrash_circuit_open, trip.(state, issue)}
    else
      candidate = next_thrash_budget_entry(state, issue.id, now_ms)

      case budget_trip_reason(candidate) do
        nil ->
          {:ok, state}

        reason ->
          tripped = trip_budget_entry(previous, candidate, reason)
          state = put_thrash_budget(state, Map.put(thrash_budget(state), issue.id, tripped))
          {:error, :thrash_circuit_open, trip.(state, issue)}
      end
    end
  end

  # A backend swap replaces the issue's existing host slot. Exclude that entry
  # from the capacity sample, but require an exact preferred-host match so the
  # workspace and on-disk rollout never migrate during the swap.
  defp redispatch_worker_slot(state, issue, preferred_worker_host) do
    capacity_state = %{state | running: Map.delete(state.running, issue.id)}

    case Launch.select_worker_host(capacity_state, issue, preferred_worker_host) do
      ^preferred_worker_host -> :ok
      :no_worker_capacity -> {:error, :no_worker_capacity}
      _other_host -> {:error, :preferred_worker_unavailable}
    end
  end

  # Time-windowed restart budget. Independent of the willRetry:false
  # hard-failure path: catches thrash that never surfaces willRetry
  # (transport timeouts, sandbox refusals, future error classes that
  # still complete a turn as :normal and reschedule as a continuation,
  # bypassing max_retry_attempts). Counts (re)dispatches per issue per
  # window and trips once they exceed `codex_thrash_max_per_window`
  # within `codex_thrash_window_seconds`. Gating here, before
  # spawn_issue_on_worker_host, means a tripped attempt pays no workspace
  # clone cost. The breaker resets when the window lapses, so the issue
  # gets another window on the next poll tick.
  #
  # The window counter is the loop-frequency guard and counts every dispatch
  # attempt. The lifetime counter is the structural-stuck latch and counts
  # only dispatches that actually survived provisioning (see
  # `record_dispatch_committed/2`) — a preflight / prewarm / tracker-auth
  # failure never reaches the runner's commit point, so it never bills the
  # ticket a lifetime unit. The gate checks both but increments neither
  # persistable lifetime: a latched ticket trips before paying workspace
  # clone cost.
  @spec check_thrash_budget(State.t(), String.t(), integer()) ::
          {:ok, State.t()} | {:trip, State.t()}
  def check_thrash_budget(%State{} = state, issue_id, now_ms) do
    previous = Map.get(thrash_budget(state), issue_id)

    if active_trip?(previous, now_ms) do
      {:trip, state}
    else
      admit_next_thrash_budget(state, issue_id, previous, now_ms)
    end
  end

  defp admit_next_thrash_budget(state, issue_id, previous, now_ms) do
    entry = next_thrash_budget_entry(state, issue_id, now_ms)

    case budget_trip_reason(entry) do
      nil ->
        state = put_thrash_budget(state, Map.put(thrash_budget(state), issue_id, entry))
        {:ok, state}

      reason ->
        tripped = trip_budget_entry(previous, entry, reason)
        state = put_thrash_budget(state, Map.put(thrash_budget(state), issue_id, tripped))
        {:trip, state}
    end
  end

  @doc false
  # Commits a lifetime dispatch unit for a ticket whose runner has survived
  # provisioning (workspace created, session about to start). This is the
  # ONLY place the lifetime counter grows: preflight, prewarm-gate, and
  # tracker-auth failures never reach it, so infrastructure faults no longer
  # walk a ticket to the latch without it ever doing agent work (#1453).
  # Returns `state` unchanged when the latch is disabled (`0`).
  @spec record_dispatch_committed(State.t(), String.t()) :: State.t()
  def record_dispatch_committed(%State{} = state, issue_id) when is_binary(issue_id) do
    case Config.agent_max_dispatches_per_ticket() do
      max when is_integer(max) and max > 0 ->
        entry = Map.get(thrash_budget(state), issue_id, %{})
        head_sha = observed_head_sha(state, issue_id)

        if noop_redispatch?(entry, head_sha) do
          skip_noop_lifetime_bill(state, issue_id, head_sha)
        else
          bill_lifetime_dispatch(state, issue_id, entry, head_sha)
        end

      _ ->
        state
    end
  end

  # The previous dispatch of this ticket left the pull request head exactly
  # where it found it, so that turn produced no pushed work. A rework turn with
  # nothing to rework must not walk the ticket toward the terminal lifetime
  # latch (#1756) — bill nothing and let the head sha stand, so an unbounded
  # run of no-op turns costs exactly the one unit already billed for the head.
  defp noop_redispatch?(entry, head_sha) do
    is_binary(head_sha) and head_sha != "" and Map.get(entry, :billed_head_sha) == head_sha
  end

  defp skip_noop_lifetime_bill(%State{} = state, issue_id, head_sha) do
    Logger.info("Lifetime dispatch unit withheld; previous turn pushed nothing: issue_id=#{issue_id} head_sha=#{head_sha}")

    state
  end

  defp bill_lifetime_dispatch(%State{} = state, issue_id, entry, head_sha) do
    lifetime = max(lifetime_of(Map.get(thrash_budget(state), issue_id)), persisted_lifetime(issue_id)) + 1
    entry = put_billed_head_sha(entry, head_sha)

    # The in-memory count is updated even when the durable write fails so
    # the latch still bounds a stuck ticket within this daemon generation
    # while the store is broken (the fail-open `persisted_lifetime/1` keeps
    # it from latching every ticket fleet-wide).
    case DispatchBudgetStore.put_lifetime(issue_id, lifetime) do
      :ok ->
        put_thrash_budget(state, Map.put(thrash_budget(state), issue_id, Map.put(entry, :lifetime, lifetime)))

      {:error, reason} ->
        Logger.error("Dispatch budget commit failed (in-memory count retained): issue_id=#{issue_id} reason=#{inspect(reason)}")
        put_thrash_budget(state, Map.put(thrash_budget(state), issue_id, Map.put(entry, :lifetime, lifetime)))
    end
  end

  defp put_billed_head_sha(entry, head_sha) when is_binary(head_sha) and head_sha != "",
    do: Map.put(entry, :billed_head_sha, head_sha)

  # An unknown head (no PR yet, an unreadable poll, the REST fallback) bills
  # normally and clears the marker, so the next dispatch cannot be mistaken for
  # a repeat of this one.
  defp put_billed_head_sha(entry, _head_sha), do: Map.delete(entry, :billed_head_sha)

  # Last pull request head the CI poller observed for this ticket. `poll_cache`
  # is refreshed on every CI poll of an active ticket and survives the agent's
  # turn ending, which is what makes it a usable before/after marker here.
  defp observed_head_sha(%State{} = state, issue_id) do
    with %Issue{} = issue <- Map.get(state.last_polled_issues, issue_id),
         target when is_binary(target) <- CiLifecycle.ci_target_for_issue(issue),
         %{head_sha: head_sha} <- state.ci_lifecycle |> Map.get(:poll_cache, %{}) |> Map.get(target) do
      head_sha
    else
      _other -> nil
    end
  end

  defp budget_trip_reason(entry) do
    cond do
      entry.count > Config.codex_thrash_max_per_window() -> :window
      lifetime_exhausted?(entry) -> :lifetime
      true -> nil
    end
  end

  defp active_trip?(%{tripped: :lifetime, lifetime: lifetime}, _now_ms) do
    case Config.agent_max_dispatches_per_ticket() do
      max when is_integer(max) and max > 0 -> lifetime >= max
      _ -> false
    end
  end

  defp active_trip?(%{tripped: :window, window_start_ms: start}, now_ms) do
    now_ms - start < Config.codex_thrash_window_seconds() * 1_000
  end

  defp active_trip?(_entry, _now_ms), do: false

  defp trip_budget_entry(previous, candidate, reason) do
    spent =
      previous ||
        %{
          window_start_ms: candidate.window_start_ms,
          count: max(candidate.count - 1, 0),
          lifetime: candidate.lifetime
        }

    spent
    |> Map.put(:tripped, reason)
    |> Map.put(:alert_emitted, false)
  end

  # The window counter resets on every lapsed window, so a ticket that churns
  # slowly (a dispatch every few minutes) never trips it — that is how a single
  # ticket accumulated 85 cold dispatches. `lifetime` counts only dispatches
  # that committed real work (see `record_dispatch_committed/2`) and survives
  # `reset_thrash_budget/2`, so a structurally-stuck ticket latches instead of
  # burning quota forever. `0` (the default) disables the latch, matching the
  # repo's existing "0 disables it" idiom.
  defp lifetime_exhausted?(%{lifetime: lifetime}) do
    case Config.agent_max_dispatches_per_ticket() do
      max when is_integer(max) and max > 0 -> lifetime >= max
      _ -> false
    end
  end

  defp next_thrash_budget_entry(state, issue_id, now_ms) do
    window_ms = Config.codex_thrash_window_seconds() * 1_000
    previous = Map.get(thrash_budget(state), issue_id)
    lifetime = max(lifetime_of(previous), persisted_lifetime(issue_id))

    next =
      case previous do
        %{window_start_ms: start, count: count} when now_ms - start < window_ms ->
          %{window_start_ms: start, count: count + 1, lifetime: lifetime}

        _ ->
          %{window_start_ms: now_ms, count: 1, lifetime: lifetime}
      end

    # The window rolls, the head marker does not: it records which pull request
    # head the lifetime counter was last billed for, and only a new head clears
    # it (see `noop_redispatch?/2`).
    carry_billed_head_sha(next, previous)
  end

  defp carry_billed_head_sha(next, %{billed_head_sha: head_sha}) when is_binary(head_sha),
    do: Map.put(next, :billed_head_sha, head_sha)

  defp carry_billed_head_sha(next, _previous), do: next

  defp lifetime_of(%{lifetime: lifetime}) when is_integer(lifetime), do: lifetime

  defp lifetime_of(_entry), do: 0

  # Fails open: an unreadable/corrupt budget store logs loudly but returns 0
  # so a single bad JSON file cannot latch every ticket in the repo at once
  # (the pre-#1453 behaviour). The window thrash guard still bounds rapid
  # respawn loops; the lifetime latch simply degrades to disabled until the
  # store is repaired, which is the safe direction for a data-integrity fault.
  defp persisted_lifetime(issue_id) do
    case Config.agent_max_dispatches_per_ticket() do
      max when is_integer(max) and max > 0 ->
        case DispatchBudgetStore.lifetime(issue_id) do
          {:ok, lifetime} ->
            lifetime

          {:error, reason} ->
            Logger.error("Dispatch budget store read failed; treating lifetime as 0 (latch disabled): issue_id=#{issue_id} reason=#{inspect(reason)}")
            0
        end

      _ ->
        0
    end
  end

  # Single-store-read batch form for `dispatch_latch_statuses/2`; returns a
  # plain map of issue_id => lifetime (missing entries are 0) or `%{}` on an
  # unreadable store (fail-open, matching `persisted_lifetime/1`).
  defp read_lifetimes_once do
    case DispatchBudgetStore.lifetimes() do
      {:ok, lifetimes} when is_map(lifetimes) ->
        lifetimes

      {:error, reason} ->
        Logger.error("Dispatch budget store read failed; treating lifetime as 0 (latch disabled): reason=#{inspect(reason)}")
        %{}
    end
  end

  # Clears the window so an operator resume can move the ticket again, but
  # deliberately preserves `lifetime`: the dispatches that committed real work
  # were really spent, and refunding them would let a resume loop bypass the
  # latch forever. Only `reset_lifetime_budget/2` (the documented
  # `aiurdev reset-budget` exit) clears lifetime.
  @spec reset_thrash_budget(State.t(), String.t()) :: State.t()
  def reset_thrash_budget(%State{} = state, issue_id) do
    case Map.get(thrash_budget(state), issue_id) do
      %{lifetime: lifetime} when is_integer(lifetime) and lifetime > 0 ->
        entry = %{lifetime: lifetime}
        put_thrash_budget(state, Map.put(thrash_budget(state), issue_id, entry))

      _ ->
        put_thrash_budget(state, Map.delete(thrash_budget(state), issue_id))
    end
  end

  @doc """
  The supported exit from the lifetime dispatch latch: clears both the
  in-memory thrash entry and the durable `dispatch-budgets.json` entry so a
  latched ticket returns to dispatchable without hand-editing the store.

  Returns `{state, :ok}` when the durable clear succeeded, or
  `{state, {:error, reason}}` when the in-memory entry was cleared but the
  durable store write failed — the ticket is dispatchable this generation but
  would re-latch on restart, and the caller must surface the error rather than
  report success (#1453 review P2b).
  """
  @spec reset_lifetime_budget(State.t(), String.t()) :: {State.t(), :ok | {:error, term()}}
  def reset_lifetime_budget(%State{} = state, issue_id) when is_binary(issue_id) do
    # Fully delete the in-memory entry (unlike `reset_thrash_budget/2`, which
    # deliberately preserves lifetime so an operator resume cannot refund it) —
    # this is the documented operator exit, and it must clear both copies.
    state = put_thrash_budget(state, Map.delete(thrash_budget(state), issue_id))

    case DispatchBudgetStore.reset(issue_id) do
      :ok -> {state, :ok}
      {:error, reason} -> {state, {:error, reason}}
    end
  end

  @doc """
  Reports whether a ticket is currently held by the lifetime dispatch latch.
  Used by the resume path (so `aiurdev resume` names the latch instead of
  silently no-opping) and by the idle-reason classification surfaced for
  #1457. Returns `:none` when the latch is disabled, the ticket is under the
  cap, or no durable spend is recorded.
  """
  @spec dispatch_latch_status(State.t(), String.t()) ::
          :none | {:lifetime, non_neg_integer(), pos_integer()}
  def dispatch_latch_status(%State{} = state, issue_id) when is_binary(issue_id) do
    case Config.agent_max_dispatches_per_ticket() do
      max when is_integer(max) and max > 0 ->
        lifetime = max(lifetime_of(Map.get(thrash_budget(state), issue_id)), persisted_lifetime(issue_id))

        if lifetime >= max do
          {:lifetime, lifetime, max}
        else
          :none
        end

      _ ->
        :none
    end
  end

  @doc false
  # Batch variant for the dashboard idle snapshot: the durable budget store is
  # read once for the whole board instead of once per idle ticket, so a fleet
  # of N idle rows costs one file read per snapshot rather than N.
  @spec dispatch_latch_statuses(State.t(), [String.t()]) ::
          %{String.t() => :none | {:lifetime, non_neg_integer(), pos_integer()}}
  def dispatch_latch_statuses(%State{} = state, issue_ids) when is_list(issue_ids) do
    max = Config.agent_max_dispatches_per_ticket()
    latch_enabled? = max > 0

    persisted =
      if latch_enabled? do
        read_lifetimes_once()
      else
        %{}
      end

    Map.new(issue_ids, fn issue_id ->
      lifetime = max(lifetime_of(Map.get(thrash_budget(state), issue_id)), Map.get(persisted, issue_id, 0))

      status =
        if latch_enabled? and lifetime >= max do
          {:lifetime, lifetime, max}
        else
          :none
        end

      {issue_id, status}
    end)
  end

  @doc false
  @spec thrash_budget(State.t()) :: map()
  def thrash_budget(state), do: state.dispatch_recovery.codex_thrash_budget

  @doc false
  @spec put_thrash_budget(State.t(), map()) :: State.t()
  def put_thrash_budget(state, budget), do: put_in(state.dispatch_recovery.codex_thrash_budget, budget)
end
