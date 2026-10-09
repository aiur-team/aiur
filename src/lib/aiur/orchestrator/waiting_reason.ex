defmodule Aiur.Orchestrator.WaitingReason do
  @moduledoc """
  Derives one explicit fleet-row waiting reason for OCC-5. Every branch names
  a concrete cause or `:active` — never a generic "blocked".

  Classification and descriptions use supplied facts only. Status rows
  attach existing in-memory evidence without querying stores or persisting it.
  """

  require Logger

  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Workspace.Ownership.Retention

  @type t ::
          :waiting_for_human
          | :waiting_for_supervisor
          | :waiting_for_dependency
          | :waiting_for_ci
          | :waiting_for_review
          | :paused
          | :run_paused
          | :awaiting_dispatch
          | :paused_operator
          | :paused_transient
          | :provider_limited
          | :latched_lifetime
          | :tracker_unavailable
          | :backing_off
          | :unresponsive
          | :claim_released
          | :orphaned_claim
          | :stale_claim
          | :workspace_retained
          | :workspace_ownership_waiting
          | :active

  # JSON-safe names identify the part that can clear the wait.
  @owners %{
    waiting_for_human: "Executor",
    waiting_for_supervisor: "Executor",
    waiting_for_dependency: "DispatchPolicy",
    waiting_for_ci: "CiLifecycle",
    waiting_for_review: "Executor",
    paused: "PauseResume",
    run_paused: "PauseResume",
    awaiting_dispatch: "Dispatcher",
    paused_operator: "PauseResume",
    paused_transient: "AutoResume",
    provider_limited: "RateLimitFallback",
    latched_lifetime: "Dispatcher",
    tracker_unavailable: "Dispatcher",
    backing_off: "RetryEngine",
    unresponsive: "RuntimeWatchdog",
    claim_released: "AutoResume",
    orphaned_claim: "StartupClaimReconciler",
    stale_claim: "Reconciler",
    workspace_ownership_waiting: "Workspace.Ownership",
    workspace_retained: "Workspace.Ownership",
    active: "AgentRunner"
  }

  @spec describe(t(), map()) :: map()
  def describe(reason, facts) do
    {cause, since} = evidence(reason, facts)
    owner = if reason == :backing_off and facts[:capacity_hold_active?], do: "Dispatcher", else: Map.fetch!(@owners, reason)
    %{reason: reason, owner: owner, cause: cause || :unknown, since: since}
  end

  defp evidence(:backing_off, %{capacity_hold_active?: true} = facts), do: {facts[:hold_cause], facts[:hold_since]}
  defp evidence(:backing_off, facts), do: {facts[:error], facts[:last_failure_at]}

  defp evidence(:paused_transient, %{auto_resume_cause: cause} = facts) when not is_nil(cause),
    do: {cause, facts[:auto_resume_since]}

  defp evidence(reason, facts) when reason in [:paused, :paused_operator, :paused_transient, :provider_limited],
    do: {facts[:pause_reason], facts[:paused_at]}

  defp evidence(:run_paused, facts), do: {facts[:global_pause][:source] || facts[:pause_reason], facts[:global_pause][:paused_at]}

  defp evidence(:waiting_for_human, %{open_decision_count: count} = facts) when is_integer(count) and count > 0,
    do: {%{open_decision_count: count}, facts[:human_wait_since]}

  defp evidence(:waiting_for_human, facts), do: {facts[:pause_reason], facts[:human_wait_since] || facts[:paused_at]}

  # No recorded start exists for these two waits: a normalized blocker edge
  # carries no creation time, and the lifetime latch persists only a dispatch
  # count. They report `since: nil` ("since unknown"), never another clock.
  defp evidence(:waiting_for_dependency, facts), do: {facts[:blocked_by], nil}
  defp evidence(:latched_lifetime, facts), do: {facts[:dispatch_latch], nil}

  defp evidence(:claim_released, facts), do: {facts[:claim_release_cause], facts[:released_at]}
  defp evidence(:workspace_retained, facts), do: {facts[:workspace_retention][:cause], facts[:workspace_retention][:since]}
  defp evidence(:workspace_ownership_waiting, facts), do: {facts[:workspace_wait][:cause] || facts[:workspace_wait][:owner], facts[:workspace_wait][:since]}
  defp evidence(:unresponsive, facts), do: {:activity_timeout, facts[:last_codex_timestamp] || facts[:started_at]}
  defp evidence(:tracker_unavailable, facts), do: {facts[:dispatch_hold_reason], facts[:hold_since]}
  defp evidence(:awaiting_dispatch, facts), do: {facts[:work_state], facts[:started_at]}
  defp evidence(:active, facts), do: {:active, facts[:started_at]}

  # Collapsed cause: these waits have no cause evidence on the row, so they
  # name the collapse instead of guessing a specific cause.
  defp evidence(_reason, _facts), do: {:unknown, nil}

  @doc false
  @spec attach(map(), map(), map()) :: map()
  def attach(row, state, entry \\ %{}) do
    now = DateTime.utc_now()
    facts = Map.merge(entry, row) |> Map.merge(wait_facts(row, state, now))
    waiting = row.waiting_reason |> describe(facts) |> fence_wait(entry)
    waiting = Map.put(waiting, :age_ms, age_ms(waiting.since, now))
    Map.put(row, :waiting, waiting)
  end

  defp wait_facts(row, state, now) do
    release = Map.get(state.released_claims, row.issue_id) || %{}
    resume = Map.get(state.auto_resume, row.issue_id) || %{}
    hold = if(row[:capacity_hold_active?], do: state.capacity_hold, else: state.dispatch_hold) || %{}

    %{
      global_pause: state.global_pause,
      auto_resume_cause: resume[:cause],
      auto_resume_since: monotonic_since(resume[:scheduled_at_ms], now),
      human_wait_since: get_in(state.waiting_for_human_episodes, [row.identifier, :since]),
      released_at: monotonic_since(release[:released_at_ms], now),
      hold_since: monotonic_since(hold[:held_since_ms], now),
      hold_cause: hold[:detail] || hold[:signal],
      workspace_retention: retained(row.identifier),
      workspace_wait: workspace_wait(state, row.issue_id, row.identifier)
    }
  end

  # A pending fence names who holds the row and since when; the reason atom
  # stays the row's own classification.
  defp fence_wait(waiting, %{lifecycle_fence: %{pending_item_ids: ids, opened_at: since}} = entry) do
    if Map.get(entry[:control] || %{}, :status) != :deactivated and MapSet.size(ids) > 0 and waiting.reason in [:active, :awaiting_dispatch] do
      Map.merge(waiting, %{owner: "LifecycleFence", cause: :provider_delivery_pending, since: since, pending_item_ids: Enum.sort(ids)})
    else
      waiting
    end
  end

  defp fence_wait(waiting, _entry), do: waiting

  defp monotonic_since(nil, _now), do: nil
  defp monotonic_since(since_ms, now), do: DateTime.add(now, -elapsed(System.monotonic_time(:millisecond) - since_ms), :millisecond)

  defp age_ms(%DateTime{} = since, now), do: elapsed(DateTime.diff(now, since, :millisecond))

  defp age_ms(since, now) when is_binary(since) do
    case DateTime.from_iso8601(since) do
      {:ok, at, _offset} -> age_ms(at, now)
      _invalid -> nil
    end
  end

  defp age_ms(_since, _now), do: nil

  defp elapsed(ms) when ms < 0 do
    Logger.warning("Waiting reason timestamp is in the future; clamping age #{ms}ms")
    0
  end

  defp elapsed(ms), do: ms

  @spec render_wait(map()) :: String.t()
  def render_wait(%{waiting: %{reason: :active, owner: "AgentRunner"}}), do: ""

  def render_wait(%{waiting: %{reason: reason, owner: owner, age_ms: age} = waiting}),
    do: " · #{render(reason)} · #{owner} · #{render_age(age)}" <> render_pending_ids(waiting)

  def render_wait(_row), do: ""

  defp render_pending_ids(%{pending_item_ids: ids}), do: " · pending_item_ids=#{inspect(ids)}"
  defp render_pending_ids(_waiting), do: ""

  defp render_age(nil), do: "since unknown"
  defp render_age(ms), do: "#{div(ms, 1_000)}s"

  @spec public_wait(map()) :: map() | nil
  def public_wait(%{waiting: waiting}) do
    Map.update!(waiting, :cause, fn cause ->
      if match?({:ok, _}, Jason.encode(cause)), do: cause, else: inspect(cause)
    end)
  end

  def public_wait(_row), do: nil

  defp retained(nil), do: nil
  defp retained(identifier), do: Retention.for_ticket(identifier)

  @doc false
  @spec workspace_recovery?(map(), term(), term()) :: boolean()
  def workspace_recovery?(state, issue_id, identifier), do: not is_nil(workspace_wait(state, issue_id, identifier))

  defp workspace_wait(state, issue_id, identifier) do
    ownership = state.dispatch_recovery.workspace_ownership

    Enum.find_value([ownership.waits, ownership.ready], &find_workspace_wait(&1, issue_id, identifier))
  end

  defp find_workspace_wait(envelopes, issue_id, identifier) when is_map(envelopes) do
    Enum.find_value(envelopes, fn {key, envelope} ->
      if key == issue_id or (not is_nil(identifier) and key == identifier) or
           (is_map(envelope) and (matches?(envelope, :issue_id, issue_id) or matches?(envelope, :identifier, identifier))),
         do: workspace_envelope(envelope)
    end)
  end

  defp find_workspace_wait(_envelopes, _issue_id, _identifier), do: nil

  defp workspace_envelope(envelope) when is_map(envelope), do: envelope
  defp workspace_envelope(_envelope), do: %{}

  defp matches?(_envelope, _key, nil), do: false
  defp matches?(envelope, key, value), do: Map.get(envelope, key) == value

  @doc """
  Classifies a row backed by a live running process.

  `attrs`:
    * `:tracker_state` — the tracker issue's state string
    * `:pause_reason` — the running entry's `paused_reason` atom, if any
    * `:work_state` — the running entry's `control.status` (`:working` /
      `:paused` / `:sleeping` / `:deactivated`)
    * `:open_decision_count` — open blocking ticket Commands
    * `:stale_for_seconds` — seconds since last observed agent activity
    * `:stall_timeout_seconds` — `Config.agent_stall_timeout_ms/0` in seconds
  """
  @spec for_running(map()) :: t()
  def for_running(%{} = attrs) do
    tracker_reason = by_tracker_state(Map.get(attrs, :tracker_state))

    cond do
      open_decision?(Map.get(attrs, :open_decision_count)) -> :waiting_for_human
      Map.get(attrs, :workspace_retained?) -> :workspace_retained
      Map.get(attrs, :work_state) == :completed -> :awaiting_dispatch
      unresponsive?(attrs) -> :unresponsive
      # A duration-capped pause is one consistent state, never re-labelled by
      # whatever the tracker state happens to be. #2310 and #2311 paused for
      # the same `max_agent_duration` reason rendered `waiting_for_human` and
      # `paused` depending on their tracker state; "maximum agent duration
      # reached" is a local pause, not a tracker wait, so it always reads
      # `paused` (an open decision above still wins — it is a separate cause).
      duration_capped_pause?(attrs) -> :paused
      true -> running_reason(attrs, tracker_reason)
    end
  end

  # The residual classification once the overrides (open decision, completed,
  # unresponsive, duration cap) are ruled out: tracker state first, then the
  # pause-reason-specific labels, then the `:paused`/`:sleeping` work state.
  defp running_reason(attrs, tracker_reason) do
    if tracker_reason != :active do
      tracker_reason
    else
      running_state_reason(attrs)
    end
  end

  defp duration_capped_pause?(%{pause_reason: :max_agent_duration, work_state: :paused}),
    do: true

  defp duration_capped_pause?(_attrs), do: false

  @doc "Every retry-queue row is backing off by definition."
  @spec for_retry() :: t()
  def for_retry, do: :backing_off

  @spec render(t()) :: String.t()
  def render(:waiting_for_human), do: "waiting_for_human"
  def render(:waiting_for_supervisor), do: "waiting_for_supervisor"
  def render(:waiting_for_dependency), do: "waiting_for_dependency"
  def render(:waiting_for_ci), do: "waiting_for_ci"
  def render(:waiting_for_review), do: "waiting_for_review"
  def render(:paused), do: "paused"
  def render(:run_paused), do: "run_paused"
  def render(:awaiting_dispatch), do: "awaiting_dispatch"
  def render(:paused_operator), do: "paused_operator"
  def render(:paused_transient), do: "paused_transient"
  def render(:provider_limited), do: "provider_limited"
  def render(:latched_lifetime), do: "latched_lifetime"
  def render(:tracker_unavailable), do: "tracker_unavailable"
  def render(:backing_off), do: "backing_off"
  def render(:unresponsive), do: "unresponsive"
  def render(:claim_released), do: "claim_released"
  def render(:orphaned_claim), do: "orphaned_claim"
  def render(:workspace_ownership_waiting), do: "workspace_ownership_waiting"
  def render(:stale_claim), do: "stale_claim"
  def render(:active), do: "active"
  def render(other), do: to_string(other)

  @doc """
  Classifies a tracker-active row with no live running process.
  An open decision takes precedence, followed by `blocked_by_open?`, which is
  only ever true for a `todo` issue with an unresolved dependency (see
  `DispatchPolicy.todo_issue_blocked_by_non_terminal?/2`).

  The fourth argument is a keyword list of idle-reason evidence so #1457 can
  render *why* a row is idle rather than a bare "idle":

    * `:latched_lifetime` — true when the ticket is held by the lifetime
      dispatch latch (`Dispatcher.dispatch_latch_status/2` != `:none`); not
      resume-clearable
    * `:tracker_paused` — true when the operator's `agent:paused` label
      override is present (`Issue.paused?/1`)
    * `:auto_resume_retry_in_ms` — non-nil when a transient-caused pause/error
      has a pending automatic resume (`Aiur.Orchestrator.AutoResume.retry_in_ms/3`)
    * `:capacity_hold_active?` — true when host-pressure admission is currently
      deferring dispatchable work, so a ready row reads as `:backing_off`
      (capacity) rather than `:active`
    * `:dispatch_hold_reason` — the fleet-wide reason selection did not run;
      `:tracker_preflight` renders an otherwise-ready row as
      `:tracker_unavailable`
    * `:workspace_recovery?` — true when the ticket is parked in
      `dispatch_recovery.workspace_ownership` (`waits` or `ready`) because its
      previous session still owned the workspace when the redispatch ran. The
      row has no live agent by design and the next dispatch poll reclaims it,
      so it must never read as an `:orphaned_claim` strand (#2810).
    * `:startup_reconciliation_complete?` — whether the one-shot startup claim
      pass finished. Before it runs, an idle in-progress row is an
      `:orphaned_claim` awaiting the pass (criterion 4); after it, the same row
      is a post-pass `:stale_claim` — never the healthy `awaiting-dispatch`
      text that masked the original fleet stall.

  Precedence: an open decision, then a dependency, then the more specific
  #1453 causes (latch > operator pause > pending transient resume), then a
  capacity hold (which only reclassifies the `:active` fallback), then the
  tracker-state classification.
  """
  @spec for_idle(String.t() | nil, boolean(), non_neg_integer(), keyword()) :: t()
  def for_idle(tracker_state, blocked_by_open?, open_decision_count, opts \\ [])

  def for_idle(_tracker_state, _blocked_by_open?, open_decision_count, _opts)
      when open_decision_count > 0, do: :waiting_for_human

  def for_idle(_tracker_state, true, 0, _opts), do: :waiting_for_dependency
  def for_idle(tracker_state, false, 0, opts), do: idle_classification(tracker_state, opts)

  # A lifetime latch wins over a label pause (the latch is not resume-clearable
  # and `resume` cannot move it); an operator pause wins over a pending transient
  # resume (an operator's explicit pause supersedes an automatic one); a
  # capacity hold only reclassifies the `:active` fallback, so it never masks a
  # specific #1453 cause.
  defp idle_classification(tracker_state, opts) do
    cond do
      Keyword.get(opts, :latched_lifetime, false) ->
        :latched_lifetime

      Keyword.get(opts, :tracker_paused, false) ->
        :paused_operator

      Keyword.get(opts, :auto_resume_retry_in_ms) != nil ->
        :paused_transient

      # A workspace-ownership hold has a named owner and a queued redispatch
      # envelope. Release may require provider-exit proof, so it is not always
      # self-clearing. It outranks the tracker-state classifications below,
      # which would misreport the row as an orphaned or stale claim (#2810).
      Keyword.get(opts, :workspace_retained?, false) ->
        :workspace_retained

      Keyword.get(opts, :workspace_recovery?, false) ->
        :workspace_ownership_waiting

      Keyword.get(opts, :dispatch_hold_reason) == :tracker_preflight ->
        dispatch_hold_or_tracker_state(tracker_state, opts)

      Keyword.get(opts, :capacity_hold_active?, false) ->
        capacity_or_tracker_state(tracker_state, opts)

      true ->
        idle_by_tracker_state(tracker_state, opts)
    end
  end

  # A capacity hold only reclassifies dispatchable rows (the `:active` fallback)
  # as `:backing_off`; rows waiting on CI, review, etc. keep their own reason.
  defp capacity_or_tracker_state(tracker_state, opts) do
    case idle_by_tracker_state(tracker_state, opts) do
      :active -> :backing_off
      other -> other
    end
  end

  defp dispatch_hold_or_tracker_state(tracker_state, opts) do
    case idle_by_tracker_state(tracker_state, opts) do
      :active -> :tracker_unavailable
      other -> other
    end
  end

  # Mirrors `Aiur.Orchestrator.RuntimeWatchdog.restart_stalled_issue/5`'s
  # actual exemption set: only `:paused` and `:deactivated` entries are
  # skipped by the stall-restart check there, so a `:sleeping` entry is just
  # as eligible for a stall-triggered kill+retry as a `:working` one — this
  # must classify it the same way, or the dashboard would keep calling it
  # merely "paused" right up to the restart.
  defp unresponsive?(%{
         work_state: work_state,
         stale_for_seconds: stale,
         stall_timeout_seconds: timeout
       })
       when work_state in [:working, :sleeping] and is_integer(stale) and is_integer(timeout) and
              timeout > 0,
       do: stale >= timeout

  defp unresponsive?(_attrs), do: false

  defp open_decision?(count), do: is_integer(count) and count > 0

  defp running_state_reason(attrs) do
    cond do
      Map.get(attrs, :pause_reason) == :github_budget_hold -> :paused_transient
      # A provider account limit is a wait on the provider's reset, not on a
      # human (#2737). The rate-limit fallback resumes it.
      provider_limited?(attrs) -> :provider_limited
      agent_requested_human?(Map.get(attrs, :pause_reason)) -> :waiting_for_human
      Map.get(attrs, :pause_reason) == :global_pause -> :run_paused
      Map.get(attrs, :work_state) in [:paused, :sleeping] -> :paused
      true -> :active
    end
  end

  defp agent_requested_human?(reason), do: reason == :input_required

  defp provider_limited?(%{pause_reason: :usage_limit_exhausted, work_state: :paused}), do: true
  defp provider_limited?(_attrs), do: false

  @doc """
  True when a fleet row's derived waiting reason is `:waiting_for_human`.

  Every operator surface that says "waiting for a human" asks this one
  question of the row's `waiting_reason`, so `aiur status` and `aiur agents`
  can never disagree about the same ticket (#2698). Accepts the atom or its
  rendered string, because rows can cross a serialization boundary.
  """
  @spec waiting_for_human?(map()) :: boolean()
  def waiting_for_human?(%{waiting_reason: reason}) when reason in [:waiting_for_human, "waiting_for_human"],
    do: true

  def waiting_for_human?(_row), do: false

  # An idle in-progress row has a tracker claim but no live runtime. Before the
  # one-shot startup pass runs it is an `:orphaned_claim` awaiting recovery;
  # after the pass completes it is a post-pass `:stale_claim`. Either way it is
  # never the healthy `awaiting-dispatch [waiting=active]` text that masked the
  # original fleet stall.
  defp idle_by_tracker_state(state, opts) do
    case DispatchPolicy.normalize_issue_state(state) do
      state when state in ["in-progress", "in progress"] ->
        if Keyword.get(opts, :startup_reconciliation_complete?, false),
          do: :stale_claim,
          else: :orphaned_claim

      _other ->
        by_tracker_state(state)
    end
  end

  # `rework` is deliberately absent: it is agent-owned work (the agent addresses
  # review feedback), not a wait on a human. Only an open decision or an
  # agent's own request for input may read `:waiting_for_human`, so `aiur
  # status` and `aiur agents` derive the human wait from the same fact (#2698).
  defp by_tracker_state(state) when is_binary(state) do
    case state |> String.downcase() |> String.trim() do
      "ci-wait" -> :waiting_for_ci
      "human-review" -> :waiting_for_review
      "merging" -> :waiting_for_supervisor
      _ -> :active
    end
  end

  defp by_tracker_state(_state), do: :active
end
