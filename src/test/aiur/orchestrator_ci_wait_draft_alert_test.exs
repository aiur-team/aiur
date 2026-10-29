defmodule Aiur.OrchestratorCiWaitDraftAlertTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.{CiLifecycle, State}

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github")
    :ok
  end

  test "alerts after a draft has remained in ci-wait without requiring a worker rewake" do
    identifier = "ci-wait-draft-#{System.unique_integer([:positive])}"
    topic = "ticket.#{identifier}.pr.draft_ci_wait"
    ref = make_ref()
    issue = %Issue{id: identifier, identifier: identifier, state: "ci-wait"}
    result = %{decision: :pending, pending_reason: :draft_pull_request, pr_number: 943, draft?: true}

    emitter = fn alert_topic, opts ->
      send(self(), {:alert, ref, alert_topic, opts})
      :ok
    end

    first = poll_ci(%State{}, issue, result, emitter, 1_000)
    refute_received {:alert, ^ref, ^topic, _opts}

    _overdue = poll_ci(first, issue, result, emitter, 1_000 + 5 * 60_000)

    assert_received {:alert, ^ref, ^topic, alert_opts}
    assert Keyword.get(alert_opts, :needs_attention) == true
  end

  test "moves an unattended draft ticket to rework with a reason comment and attention" do
    identifier = "ci-wait-draft-rework-#{System.unique_integer([:positive])}"
    topic = "ticket.#{identifier}.pr.draft_ci_wait"
    ref = make_ref()
    issue = %Issue{id: identifier, identifier: identifier, state: "ci-wait"}
    result = %{decision: :pending, pending_reason: :draft_pull_request, pr_number: 951, draft?: true}

    emitter = fn alert_topic, opts ->
      send(self(), {:alert, ref, alert_topic, opts})
      :ok
    end

    previous_recipient = Application.get_env(:aiur, :memory_tracker_recipient)
    previous_issues = Application.get_env(:aiur, :memory_tracker_issues)
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    Application.put_env(:aiur, :memory_tracker_issues, [issue])

    on_exit(fn ->
      if previous_recipient, do: Application.put_env(:aiur, :memory_tracker_recipient, previous_recipient), else: Application.delete_env(:aiur, :memory_tracker_recipient)
      if previous_issues, do: Application.put_env(:aiur, :memory_tracker_issues, previous_issues), else: Application.delete_env(:aiur, :memory_tracker_issues)
    end)

    comment = fn id, body ->
      send(self(), {:comment, id, body})
      :ok
    end

    transition = fn state, ticket ->
      send(self(), {:transition, ticket.identifier, "rework"})
      {:ok, state}
    end

    first = poll_ci(%State{}, issue, result, emitter, 1_000, comment, transition)
    overdue = poll_ci(first, issue, result, emitter, 1_000 + 60 * 60_000, comment, transition)

    assert is_struct(overdue, State)
    assert_received {:comment, ^identifier, "PR is still a draft; finish and mark ready"}
    assert_received {:transition, ^identifier, "rework"}
    assert_received {:alert, ^ref, ^topic, alert_opts}
    assert Keyword.get(alert_opts, :needs_attention)
    assert alert_opts[:message] =~ identifier
    assert alert_opts[:message] =~ "#951"
    assert MapSet.member?(overdue.ci_lifecycle.ci_wait_draft_recovered, identifier)
  end

  test "does not mark recovery complete when the state write fails" do
    identifier = "ci-wait-draft-retry-#{System.unique_integer([:positive])}"
    issue = %Issue{id: identifier, identifier: identifier, state: "ci-wait"}
    result = %{decision: :pending, pending_reason: :draft_pull_request, pr_number: 953, draft?: true}
    ref = make_ref()

    emitter = fn topic, opts ->
      send(self(), {:alert, ref, topic, opts})
      :ok
    end

    comment = fn _id, _body -> :ok end
    failing_transition = fn state, _ticket -> {:error, :tracker_unavailable, state} end

    state = poll_ci(%State{}, issue, result, emitter, 1_000, comment, failing_transition)
    state = poll_ci(state, issue, result, emitter, 1_000 + 60 * 60_000, comment, failing_transition)

    refute MapSet.member?(Map.get(state.ci_lifecycle, :ci_wait_draft_recovered, MapSet.new()), identifier)
    assert_received {:alert, ^ref, _, _}
  end

  test "retries a failed attention publish before moving the ticket to rework" do
    identifier = "ci-wait-draft-alert-retry-#{System.unique_integer([:positive])}"
    issue = %Issue{id: identifier, identifier: identifier, state: "ci-wait"}
    result = %{decision: :pending, pending_reason: :draft_pull_request, pr_number: 954, draft?: true}
    ref = make_ref()

    emitter = fn topic, opts ->
      attempt = Process.get(:draft_alert_attempt, 0) + 1
      Process.put(:draft_alert_attempt, attempt)
      result = if attempt == 1, do: {:error, :temporarily_unavailable}, else: :ok
      send(self(), {:alert_attempt, ref, topic, opts, result})
      result
    end

    transition = fn state, _ticket ->
      send(self(), {:transition, ref})
      {:ok, state}
    end

    comment = fn _id, _body -> :ok end
    state = poll_ci(%State{}, issue, result, emitter, 1_000, comment, transition)
    state = poll_ci(state, issue, result, emitter, 1_000 + 60 * 60_000, comment, transition)

    assert_received {:alert_attempt, ^ref, _, _, {:error, :temporarily_unavailable}}
    refute_received {:transition, ^ref}
    refute MapSet.member?(Map.get(state.ci_lifecycle, :ci_wait_draft_recovered, MapSet.new()), identifier)

    state = poll_ci(state, issue, result, emitter, 1_001 + 60 * 60_000, comment, transition)

    assert_received {:alert_attempt, ^ref, _, _, :ok}
    assert_received {:transition, ^ref}
    assert MapSet.member?(state.ci_lifecycle.ci_wait_draft_recovered, identifier)
  end

  test "leaves an overdue draft ticket alone while a worker is live" do
    identifier = "ci-wait-draft-live-#{System.unique_integer([:positive])}"
    issue = %Issue{id: identifier, identifier: identifier, state: "ci-wait"}
    result = %{decision: :pending, pending_reason: :draft_pull_request, pr_number: 952, draft?: true}
    ref = make_ref()

    emitter = fn topic, opts ->
      send(self(), {:alert, ref, topic, opts})
      :ok
    end

    worker = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(worker, :kill) end)
    state = put_in(%State{}.running[identifier], %{pid: worker, control: %{status: :working}})

    _state = poll_ci(state, issue, result, emitter, 1_000 + 61 * 60_000)

    refute_received {:alert, ^ref, _, _}
    refute_received {:comment, _, _}
    refute_received {:memory_tracker_state_update, _, _}
  end

  test "resolves when the draft clears and starts a fresh alert delay on re-entry" do
    identifier = "ci-wait-draft-reentry-#{System.unique_integer([:positive])}"
    alert_topic = "ticket.#{identifier}.pr.draft_ci_wait"
    resolved_topic = alert_topic <> ".resolved"
    ref = make_ref()
    issue = %Issue{id: identifier, identifier: identifier, state: "ci-wait"}
    draft = %{decision: :pending, pending_reason: :draft_pull_request, pr_number: 944, draft?: true}
    ready = %{decision: :pending, pending_reason: :required_checks_pending, pr_number: 944, draft?: false}

    emitter = fn topic, opts ->
      send(self(), {:alert, ref, topic, opts})
      :ok
    end

    state = poll_ci(%State{}, issue, draft, emitter, 1_000)
    state = poll_ci(state, issue, draft, emitter, 301_000)
    assert_received {:alert, ^ref, ^alert_topic, _opts}

    state = poll_ci(state, issue, ready, emitter, 302_000)
    assert_received {:alert, ^ref, ^resolved_topic, resolved_opts}
    assert Keyword.get(resolved_opts, :needs_attention) == false

    state = poll_ci(state, issue, draft, emitter, 400_000)
    refute_received {:alert, ^ref, ^alert_topic, _opts}

    state = poll_ci(state, issue, draft, emitter, 700_000)
    assert_received {:alert, ^ref, ^alert_topic, alert_opts}
    assert Keyword.get(alert_opts, :needs_attention) == true

    outside_ci_wait = %{issue | state: "in-progress"}
    _state = poll_ci(state, outside_ci_wait, draft, emitter, 701_000)
    assert_received {:alert, ^ref, ^resolved_topic, resolved_opts}
    assert Keyword.get(resolved_opts, :needs_attention) == false
  end

  defp poll_ci(state, issue, result, emitter, now_ms, comment \\ nil, transition \\ nil) do
    # Each call is a separate tick; a published :ci cadence must not skip it (#4360).
    opts =
      [
        ci_failure_digest: fn _, _ -> {:ok, %Aiur.CI.FailureDigest{}} end,
        parked_ready_alert_loader: fn -> MapSet.new() end,
        draft_stall_alert_loader: fn -> MapSet.new() end,
        ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
        ci_poller: fn [target], _opts -> {:ok, %{results: [Map.put(result, :target, target)], errors: []}} end,
        alert_emitter: emitter,
        ci_wait_draft_now_ms: now_ms,
        ci_wait_draft_timeout_minutes: 60,
        ci_wait_rewake_minutes: 5,
        tracker: Aiur.Memory.Tracker
      ]
      |> maybe_put(:draft_stall_comment, comment)
      |> maybe_put(:draft_stall_transition, transition)

    CiLifecycle.poll_github_ci(%{state | last_ci_poll_started_at_ms: nil}, opts)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
