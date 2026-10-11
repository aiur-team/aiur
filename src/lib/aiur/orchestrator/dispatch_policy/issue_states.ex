defmodule Aiur.Orchestrator.DispatchPolicy.IssueStates do
  @moduledoc """
  Issue-state normalization, classification, and contradictory-label resolution. Public API stays on `Aiur.Orchestrator.DispatchPolicy`.
  """

  alias Aiur.Config

  # States in which, by definition, there is no agent work: the PR is sitting in
  # GitHub's merge queue (`merging`) or CI is in flight (`ci-wait`). Dispatching
  # into them cannot produce progress, only cost — and every committed dispatch
  # bills a lifetime unit, so a ticket can burn the terminal (self-declared
  # unrecoverable) latch while waiting for the merge queue, *after* its work was
  # finished and approved (#1759: 48 dispatches in ~50 minutes on a ticket in
  # `merging` with an approved, queued PR).
  #
  # This is a code-level refusal rather than an `active_states` edit because
  # `merging` must stay an active state for comment polling
  # (`CommentPolling.TargetSelection`), the paused-agent sweep, and terminal-fence
  # bookkeeping. `ci-wait` is already excluded from the Executor's paused-agent
  # sweep as legitimate waiting; refusing it here makes the two beliefs
  # consistent regardless of how an operator configures `active_states`.
  #
  # Neither state strands a ticket: leaving `ci-wait` (the CI result delivery and
  # the `ci_wait_rewake` fallback) and leaving `merging` (a trusted comment
  # promoting the ticket to `rework`) both transition the tracker label *first*,
  # so dispatch is re-evaluated against the new state.
  @no_agent_work_states ["merging", "ci-wait"]

  # A tracker-closed ticket is terminal no matter what `tracker.terminal_states`
  # lists. The GitHub tracker resolves a `state: "closed"` payload to the state
  # "Closed" (`Aiur.GitHub.Issues.extract_state/2`), which is not an `agent:*`
  # label and therefore never appears in the configured terminal set. Without
  # this, a `blocked_by` blocker that is CLOSED on GitHub reads as non-terminal
  # and holds its blockee undispatchable forever (#2545) — a closed issue cannot
  # be blocking anything.
  @closed_issue_state "closed"

  @doc """
  True when the state is terminal: either configured in `tracker.terminal_states`
  or the tracker's own closed state (see `@closed_issue_state`).

  A non-binary state (an unlabeled ticket, or a blocker whose payload carried no
  derivable state) is NOT terminal — dependency and lifecycle callers stay
  fail-closed on incomplete data.
  """
  @spec terminal_issue_state?(term(), MapSet.t()) :: boolean()
  def terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    normalized = normalize_issue_state(state_name)

    normalized == @closed_issue_state or MapSet.member?(terminal_states, normalized)
  end

  def terminal_issue_state?(_state_name, _terminal_states), do: false

  @doc """
  True for a state where no agent work exists, so dispatch must be refused.

  See `@no_agent_work_states`. Independent of `active_states`: an operator can
  list `merging` as active (it is, for polling and fence purposes) without making
  it dispatchable.
  """
  @spec no_agent_work_state?(term()) :: boolean()
  def no_agent_work_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) in @no_agent_work_states
  end

  def no_agent_work_state?(_state_name), do: false

  @spec active_issue_state?(term(), MapSet.t()) :: boolean()
  def active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  # Nil / non-binary state happens when the GitHub poll returns an
  # issue with no `agent:*` label — extract_state returns nil. Treat
  # as 'not active' so the reconcile cond falls through to the
  # catch-all instead of crashing the orchestrator GenServer.
  def active_issue_state?(_state_name, _active_states), do: false

  @spec normalize_issue_state(term()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  # Same nil-safety reasoning as `active_issue_state?/2` above.
  # Direct callers (routable_todo_issues, state_slots_available?,
  # effective_state_limit, running_issue_count_for_state) all feed
  # `issue.state` here without a binary guard; without this clause
  # any unlabeled issue crashes the orchestrator.
  def normalize_issue_state(_state_name), do: ""

  @spec state_slug(term()) :: String.t() | nil
  def state_slug(state_name) when is_binary(state_name) do
    state_name
    |> normalize_issue_state()
    |> String.replace(~r/[\s_]+/, "-")
    |> case do
      "" -> nil
      slug -> slug
    end
  end

  def state_slug(_state_name), do: nil

  # Explicit state precedence for contradictory-label resolution (#2437): the
  # label with the most outstanding work wins. The terminal `done` must never
  # beat `rework`/`in-progress`/`human-review`/`error` — resolving a done+rework
  # pair to `done` silently discards the outstanding work and the heal would
  # close the ticket with it. `ci-wait` is a transient sub-state that must never
  # win a resolution, so it maps to an index strictly past every other label —
  # including unknown ones (a mistyped or future state, `merging`, `cancelled`)
  # — which keeps an unknown disposition from ever losing to the transient
  # `ci-wait`. `todo` is a special case (it means "no work has been done yet"
  # rather than a disposition) handled below.
  @state_precedence ~w(rework in-progress human-review error done)
  @ci_wait_state "ci-wait"

  @doc """
  Deterministically resolves a set of contradictory `agent:*` state labels to
  the single state a ticket should be treated as.

  `rework` means "work exists and was rejected"; `todo` means "no work exists
  yet to redo". When both are present they contradict, and `todo` wins: a
  ticket that is also `todo` has not been worked, so any `rework` verdict
  stamped alongside it is the artifact of a broken writer, and "pick this up
  again" (`todo`) is the honest fallback — never a review verdict.

  Among labels that both assert a real disposition, the winner is the one with
  the most outstanding work, in the explicit precedence order `rework` >
  `in-progress` > `human-review` > `error` > `done`. Resolving the terminal
  `done` over an outstanding disposition would silently discard the work —
  nothing reopens the ticket and the heal would report the pair as healed
  exactly when the work is lost — so the order deliberately favors re-opening
  over closing (#2437). `ci-wait` is a transient sub-state and never wins a
  resolution: it means "the agent is paused waiting for CI", so any other state
  label on the ticket is the real disposition and takes precedence (a
  `ci-wait`+`rework` ticket is really a rework ticket whose stale `ci-wait` was
  never cleared). Labels outside the precedence list (`merging`, `cancelled`, a
  mistyped or future state) lose to every known disposition but still outrank
  the transient `ci-wait`, so `ci-wait` can never win a resolution; ties among
  equally-ranked labels resolve by the order the labels arrived. Empty input
  resolves to `nil`.
  """
  @spec resolve_state_labels([String.t()]) :: String.t() | nil
  def resolve_state_labels(state_labels) when is_list(state_labels) do
    normalized =
      state_labels
      |> Enum.map(&normalize_state_label/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      "todo" in normalized ->
        "todo"

      normalized == [] ->
        nil

      true ->
        Enum.min_by(normalized, &state_precedence_index/1)
    end
  end

  def resolve_state_labels(_state_labels), do: nil

  # Smaller index = more outstanding work and wins a resolution. Unknown labels
  # map one step past the known dispositions (so a mistyped or future state
  # never beats a real one) but still before `ci-wait`, which is the one label
  # that must never win a resolution — it maps past the unknowns as well. Ties
  # among equal indices resolve by the order the labels arrived.
  defp state_precedence_index(state) do
    case Enum.find_index(@state_precedence, &(&1 == state)) do
      nil when state == @ci_wait_state -> length(@state_precedence) + 1
      nil -> length(@state_precedence)
      index -> index
    end
  end

  @doc """
  Normalizes a state label to its bare, unprefixed lowercase form so both the
  GitHub ingestion shape (`"todo"`, prefix already stripped) and any
  caller-provided `"agent:todo"` resolve identically.

  Public so callers that reason about the same label set as
  `resolve_state_labels/1` — the provenance-aware heal in
  `IssueSync.reconcile_contradictory_state_labels/3` (#2805) — compare labels
  through the identical normalization instead of a near-copy of it.
  """
  @spec normalize_state_label(term()) :: String.t()
  def normalize_state_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.replace_prefix("agent:", "")
    |> String.downcase()
  end

  def normalize_state_label(_label), do: ""

  @spec terminal_state_set() :: MapSet.t()
  def terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  @spec active_state_set() :: MapSet.t()
  def active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end
end
