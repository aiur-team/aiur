defmodule Aiur.Orchestrator.PrAnchored do
  @moduledoc """
  PR-anchored routing and mid-run teardown for watched/commanded human PRs (U4, U6).
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.{Alerts, Config, Issue, TicketBranch, Workspace}
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{CommentWake, Dispatcher, Slots, State}

  @pr_anchored_state "pr-watch"

  @spec maybe_route_pr_anchored_or_legacy(
          State.t(),
          String.t() | integer(),
          String.t() | atom(),
          map(),
          pos_integer()
        ) :: State.t()
  def maybe_route_pr_anchored_or_legacy(%State{} = state, issue_number, source, event, attempt) do
    if pr_anchored_routing_enabled?() and CommentWake.trusted_comment_event?(event) and
         not CommentWake.benign_review_pass_comment?(event) do
      case resolve_pr_anchored_unit(issue_number, event) do
        {:ok, %Issue{} = pr_issue} ->
          dispatch_pr_anchored_unit(state, pr_issue, source, event, attempt)

        :legacy ->
          CommentWake.maybe_transition_idle_issue_to_rework(state, issue_number, source, event, attempt)
      end
    else
      CommentWake.maybe_transition_idle_issue_to_rework(state, issue_number, source, event, attempt)
    end
  end

  @spec maybe_stop_closed_pr_anchored_agents(State.t(), keyword()) :: State.t()
  def maybe_stop_closed_pr_anchored_agents(%State{} = state, opts \\ []) do
    if Config.tracker_kind() == "github" and Aiur.GitHub.Config.pr_watch_enabled?() do
      case pr_anchored_running_entries(state) do
        [] -> state
        entries -> stop_closed_pr_anchored_entries(state, entries, opts)
      end
    else
      state
    end
  end

  defp pr_anchored_routing_enabled? do
    Config.tracker_kind() == "github" and Aiur.GitHub.Config.pr_watch_enabled?()
  end

  # Resolve the comment's PR number N to a PR-anchored work unit, or :legacy.
  # :legacy is the safe fall-through for: a plain issue (/pulls/N 404 -> nil),
  # a closed/merged PR (nil), a legacy aiur/<N>-headed aiur PR, a fetch error,
  # or a non-integer key. The fetcher is injectable for tests via the event.
  defp resolve_pr_anchored_unit(issue_number, event) do
    with {:ok, pr_number} <- pr_number_from_identifier(issue_number),
         {:ok, %{} = pr} <- fetch_open_pull_request_for_routing(pr_number, event),
         head_ref when is_binary(head_ref) and head_ref != "" <- pr_head_ref(pr),
         false <- aiur_owned_head_ref?(head_ref, pr_number) do
      {:ok, build_pr_anchored_issue(pr_number, pr, head_ref)}
    else
      _ -> :legacy
    end
  end

  defp pr_number_from_identifier(issue_number) do
    case Integer.parse(to_string(issue_number)) do
      {pr_number, ""} when pr_number > 0 -> {:ok, pr_number}
      _ -> :error
    end
  end

  defp fetch_open_pull_request_for_routing(pr_number, event) do
    fetcher =
      case Map.get(event, :open_pull_request_fetcher) do
        fun when is_function(fun, 1) -> fun
        _ -> fn number -> GitHubClient.fetch_open_pull_request(number) end
      end

    case fetcher.(pr_number) do
      {:ok, pr} when is_map(pr) -> {:ok, pr}
      {:ok, nil} -> :legacy
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_open_pull_request, other}}
    end
  end

  defp pr_head_ref(%{"head" => %{"ref" => ref}}) when is_binary(ref), do: ref
  defp pr_head_ref(_pr), do: nil

  # A PR whose head is a legacy or readable Aiur ticket branch must keep flowing
  # through tracker reactivation, never the PR-anchored path. Only an
  # external/human branch is PR-anchored.
  defp aiur_owned_head_ref?(head_ref, pr_number) do
    TicketBranch.ticket_branch?(head_ref, pr_number)
  end

  # A synthetic, slot-respecting work unit for a watched/commanded human PR.
  # id: nil keeps it OUT of revalidate_issue_for_dispatch/3's tracker lookup
  # (there is no tracker issue); identifier: to_string(pr#) is the comment
  # topic / resume key (find_running_by_identifier); pr_head_ref tells the
  # workspace to check out the human branch instead of creating aiur/<id>.
  defp build_pr_anchored_issue(pr_number, pr, head_ref) do
    %Issue{
      id: pr_anchored_running_key(pr_number),
      identifier: to_string(pr_number),
      title: pr_field(pr, "title") || "PR ##{pr_number}",
      description: pr_field(pr, "body") || "",
      state: @pr_anchored_state,
      branch_name: head_ref,
      pr_head_ref: head_ref,
      labels: []
    }
  end

  # The running-map key for a PR-anchored unit. Distinct from any tracker issue
  # id (prefixed pr-) so two PR-anchored agents never collide on a nil key
  # and a PR-anchored unit never shadows a same-numbered tracker ticket.
  defp pr_anchored_running_key(pr_number), do: "pr-#{pr_number}"

  defp pr_field(pr, key) do
    case Map.get(pr, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  # Dispatch a PR-anchored unit through the slot-respecting worker path. We gate
  # on the global agent cap (available_slots) explicitly — should_dispatch_issue?
  # cannot be reused because its candidate_issue? requires a configured active
  # state, which a synthetic PR unit deliberately is not. The host-pressure
  # admission wrapper still applies: a PR comment starts new work and must not
  # bypass the same load gate that protects ordinary ticket dispatch. The terminal
  # dispatch skips revalidate_issue_for_dispatch/3 because there is no tracker
  # issue to revalidate and routing already proved the PR is open. When the cap
  # is full or the unit is already running/claimed, log and skip — the next
  # comment re-triggers (no agent: label is touched and no persistent state is
  # written). An admission hold is NOT a skip: see admit_pr_anchored_unit/5.
  defp dispatch_pr_anchored_unit(%State{} = state, %Issue{} = issue, source, event, attempt) do
    cond do
      Map.has_key?(state.running, issue.id) or MapSet.member?(state.claimed, issue.id) ->
        Logger.info("#{source} PR-anchored dispatch skipped; already running/claimed: pr=#{issue.identifier}")

        state

      Slots.available_slots(state) <= 0 ->
        Logger.info("#{source} PR-anchored dispatch deferred; agent cap full: pr=#{issue.identifier}")

        state

      true ->
        admit_pr_anchored_unit(state, issue, source, event, attempt)
    end
  end

  # `maybe_choose_under_load/4` runs the choose-fun only when the admission gate
  # lets the unit through, and otherwise returns state with no signal of its own.
  # A ref-keyed process-dictionary marker records whether the terminal dispatch
  # actually ran: everything here executes synchronously inside the one
  # orchestrator GenServer callback, so the put and the delete cannot interleave
  # with anything else. The alternative — inferring the outcome from
  # `state.capacity_hold` — is wrong, because a hold may already be persisted
  # from an earlier poll.
  defp admit_pr_anchored_unit(%State{} = state, %Issue{} = issue, source, event, attempt) do
    marker = make_ref()

    next_state =
      Dispatcher.maybe_choose_under_load(
        state,
        [issue],
        fn admitted, [pr_issue] ->
          Process.put(marker, :dispatched)

          # Logged only once the gate has ADMITTED the unit. Claiming "routed"
          # before the gate runs is a confident wrong reason when the gate then
          # holds (#1610).
          Logger.info("#{source} routed PR-anchored (no agent:* label, no aiur/<pr#> PR): pr=#{issue.identifier} head_ref=#{issue.pr_head_ref}")

          pr_anchored_dispatch_fun(event).(admitted, pr_issue)
        end,
        pr_anchored_admission_opts(event)
      )

    case Process.delete(marker) do
      :dispatched -> next_state
      _not_dispatched -> hold_pr_anchored_unit(next_state, issue, source, event, attempt)
    end
  end

  # A held PR-anchored unit has no `agent:*` label and no tracker row, so the
  # poll loop can never rediscover it. Re-arm the comment-wake retry chain so the
  # unit is re-offered to the gate on its own, and escalate loudly when that
  # chain is exhausted and the work really is dropped.
  defp hold_pr_anchored_unit(%State{} = state, %Issue{} = issue, source, event, attempt) do
    signal = admission_hold_signal(state.capacity_hold)

    Logger.warning(
      "#{source} PR-anchored dispatch held by the admission gate: pr=#{issue.identifier} " <>
        "head_ref=#{issue.pr_head_ref} signal=#{signal} attempt=#{attempt}"
    )

    case CommentWake.schedule_comment_wake_retry(state, issue.identifier, source, event, attempt, "admission_hold:#{signal}") do
      {retry_state, :scheduled} ->
        retry_state

      {exhausted_state, :exhausted} ->
        emit_pr_anchored_hold_alert(issue, signal, attempt)
        exhausted_state
    end
  end

  defp emit_pr_anchored_hold_alert(%Issue{} = issue, signal, attempt) do
    reason =
      "PR ##{issue.identifier} was routed as a PR-anchored unit but the host-pressure admission gate " <>
        "held it on #{signal} for all #{attempt} attempts. The unit carries no agent:* label and no " <>
        "tracker row, so nothing will retry it — comment on the PR again once the host recovers."

    Alerts.emit_system("system.dispatch.pr_anchored_held",
      reason: reason,
      needs_attention: true,
      severity: "warning"
    )
  end

  defp admission_hold_signal(%{signal: signal}), do: to_string(signal)
  defp admission_hold_signal(_hold), do: "unknown"

  defp pr_anchored_admission_opts(%{admission_probes_fun: fun}) when is_function(fun, 0), do: [admission_probes_fun: fun]
  defp pr_anchored_admission_opts(_event), do: []

  # The terminal spawn for a PR-anchored unit. Defaults to the real
  # do_dispatch_issue/4 (slot-respecting worker dispatch). Tests inject a
  # capture fun via the event so routing can be asserted without spawning a
  # real agent.
  defp pr_anchored_dispatch_fun(event) do
    case Map.get(event, :pr_anchored_dispatch_fun) do
      fun when is_function(fun, 2) -> fun
      _ -> fn state, issue -> Dispatcher.do_dispatch_issue(state, issue, nil, nil) end
    end
  end

  # Select the running entries dispatched as PR-anchored units. We key off the
  # stored %Issue{} state == @pr_anchored_state (the canonical sentinel
  # build_pr_anchored_issue/1 stamps) rather than the "pr-" running-key
  # prefix: the state is a dedicated marker nothing else uses, while a key prefix
  # is a derived convention a tracker id could collide with.
  defp pr_anchored_running_entries(%State{running: running}) do
    Enum.filter(running, fn {_issue_id, running_entry} ->
      pr_anchored_running_entry?(running_entry)
    end)
  end

  defp pr_anchored_running_entry?(%{issue: %Issue{state: @pr_anchored_state}}), do: true
  defp pr_anchored_running_entry?(_running_entry), do: false

  defp stop_closed_pr_anchored_entries(%State{} = state, entries, opts) do
    fetcher = pr_open_state_fetcher(opts)

    Enum.reduce(entries, state, fn {issue_id, running_entry}, state_acc ->
      pr_number = Map.get(running_entry, :identifier)

      case fetcher.(pr_number) do
        {:ok, nil} ->
          Logger.warning("PR-anchored agent's PR is no longer open; stopping agent and cleaning workspace: issue_id=#{issue_id} pr=#{pr_number}")

          state_acc = Orchestrator.terminate_running_issue(state_acc, issue_id, false)
          cleanup_pr_anchored_workspace(issue_id, running_entry)
          state_acc

        {:ok, _pr} ->
          # PR still open — let the agent keep working.
          state_acc

        {:error, reason} ->
          # Transient fetch failure — do NOT terminate. A real terminal state is
          # re-observed next cycle.
          Logger.warning("PR-anchored teardown PR fetch failed; leaving agent running: issue_id=#{issue_id} pr=#{pr_number} reason=#{inspect(reason)}")

          state_acc

        other ->
          Logger.warning("PR-anchored teardown PR fetch returned unexpected value; leaving agent running: issue_id=#{issue_id} pr=#{pr_number} value=#{inspect(other)}")

          state_acc
      end
    end)
  end

  defp pr_open_state_fetcher(opts) do
    case Keyword.get(opts, :open_pull_request_fetcher) do
      fun when is_function(fun, 1) -> fun
      _ -> fn pr_number -> GitHubClient.fetch_open_pull_request(pr_number) end
    end
  end

  # terminate_running_issue/3's workspace cleanup keys off the running entry's
  # identifier (the bare PR number), but a PR-anchored workspace lives at the
  # pr-<pr#> leaf (Workspace.workspace_identifier/2), which equals the
  # running-map KEY (issue.id). Clean the pr-<pr#> leaf explicitly so no
  # orphan workspace is left behind, mirroring the legacy terminal cleanup.
  defp cleanup_pr_anchored_workspace(issue_id, running_entry) when is_binary(issue_id) do
    # A closed PR is terminal for a PR-anchored unit, but this path bypasses
    # cleanup_terminal_issue_artifacts, so the resume handle is never cleared
    # for it. The handle is keyed by the PR-number identifier (what
    # start_agent_session persisted under), not the pr-<pr#> running key;
    # without this, a reopened PR would --resume the finished thread now that
    # claude-repl is resumable (#613).
    Orchestrator.clear_session_handle(Map.get(running_entry, :identifier))
    Workspace.remove_issue_workspaces(issue_id, Map.get(running_entry, :worker_host))
  end
end
