defmodule Aiur.Orchestrator.RetryEngine.ExhaustionTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.State

  # Deterministic GitHub-client stubs for the retry-exhaustion error-state write
  # (#2420): a failing write exercises the `{:error, {:no_state_label_written,
  # _}}` honesty path, a succeeding one the `:alert_emitted` path.
  defmodule FailingGitHubClient do
    def update_issue_state(_issue_id, _state_name), do: {:error, :github_down}
    def update_issue_state(_issue_id, _state_name, _opts), do: {:error, :github_down}
  end

  defmodule SucceedingGitHubClient do
    def update_issue_state(_issue_id, _state_name), do: :ok
    def update_issue_state(_issue_id, _state_name, _opts), do: :ok
  end

  defmodule HeldThenSucceedingGitHubClient do
    def update_issue_state(_issue_id, _state_name), do: update_issue_state(nil, nil, [])

    def update_issue_state(_issue_id, _state_name, _opts) do
      attempts = Process.get(:held_state_write_attempts, 0)
      Process.put(:held_state_write_attempts, attempts + 1)

      if attempts == 0 do
        hold = %{resource: "core", reason: :shared_budget, reset_at: DateTime.add(DateTime.utc_now(), -1, :second)}
        {:error, {:github, :local_hold, %{reason: {:aiur, :locally_held, hold}, hold: hold}}}
      else
        :ok
      end
    end
  end

  describe "retry_exhausted alert (#1317)" do
    test "give-up alert includes the underlying error, not just a generic headline" do
      # The Publisher contamination filter's tracked_fn is process-global
      # (:persistent_term) and can be left pointed at another test's narrow
      # set; reset it so this ticket's alert isn't silently filtered.
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.MT-ALERT-1.agent.retry_exhausted")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      RetryEngine.schedule_issue_retry(%State{}, "issue-alert-1", Config.max_retry_attempts() + 1, %{
        identifier: "MT-ALERT-1",
        # Mirrors what handle_agent_down/3 records: "agent exited: #{inspect(reason)}".
        error: "agent exited: {:workspace_git_metadata_unwritable, \"/ws/.aiur-git-index-write-probe-1\", {:git_index_probe_failed, 128}}",
        delay_type: :failure
      })

      assert_receive {:event, %{topic: "ticket.MT-ALERT-1.agent.retry_exhausted"} = event}, 500
      refute event["message"] == "Agent retry budget exhausted"
      assert event["message"] =~ "git_index_probe_failed"
      assert event["reason"] =~ "git_index_probe_failed"
    end
  end

  describe "exhaustion error-state write (#2420)" do
    # Switching the active workflow to the GitHub tracker routes
    # `Tracker.update_issue_state/2` through `:github_client_module`, which each
    # test pins to a deterministic stub. The default test workflow is the memory
    # tracker, whose writes always succeed, so it cannot exercise the failure
    # branch this describe exists to pin.
    defp with_github_tracker!(test_fn) do
      write_workflow_file!(Aiur.Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      previous_client = Application.get_env(:aiur, :github_client_module)

      on_exit(fn ->
        restore_application_env(:github_client_module, previous_client)
      end)

      test_fn.()
    end

    test "a failed terminal error-state write is reported, not swallowed as :ok" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.MT-WRITE-FAIL.agent.attention.error-state-write-failed")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      with_github_tracker!(fn ->
        Application.put_env(:aiur, :github_client_module, FailingGitHubClient)

        # F3 (#2420): a failed terminal write must surface a distinct error, not
        # a false `:ok` — a swallowed return here would leave the ticket on its
        # active-state label while the caller records a successful transition.
        assert {:error, {:no_state_label_written, "MT-WRITE-FAIL"}} =
                 RetryEngine.move_exhausted_issue_to_error_state(
                   "issue-write-fail",
                   "MT-WRITE-FAIL",
                   "agent exited: boom"
                 )

        assert_receive {:event, %{topic: "ticket.MT-WRITE-FAIL.agent.attention.error-state-write-failed"}}, 500
      end)
    end

    test "a successful terminal error-state write reports :alert_emitted and alerts" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.MT-WRITE-OK.agent.attention.error-retry_exhausted")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      with_github_tracker!(fn ->
        Application.put_env(:aiur, :github_client_module, SucceedingGitHubClient)

        assert RetryEngine.move_exhausted_issue_to_error_state(
                 "issue-write-ok",
                 "MT-WRITE-OK",
                 "agent exited: boom"
               ) == :alert_emitted

        assert_receive {:event, %{topic: "ticket.MT-WRITE-OK.agent.attention.error-retry_exhausted"}}, 500
      end)
    end

    test "a terminal state write retries and applies after a shared budget hold" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.MT-WRITE-HELD.agent.attention.error-retry_exhausted")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      with_github_tracker!(fn ->
        Application.put_env(:aiur, :github_client_module, HeldThenSucceedingGitHubClient)
        Process.put(:held_state_write_attempts, 0)

        assert :alert_emitted =
                 RetryEngine.move_exhausted_issue_to_error_state(
                   "issue-write-held",
                   "MT-WRITE-HELD",
                   "agent exited: boom"
                 )

        assert Process.get(:held_state_write_attempts) == 2
        assert_receive {:event, %{topic: "ticket.MT-WRITE-HELD.agent.attention.error-retry_exhausted"}}, 500
      end)
    end

    test "a held issue-state refresh is transient and does not write terminal error" do
      with_github_tracker!(fn ->
        Application.put_env(:aiur, :github_client_module, FailingGitHubClient)

        assert :ok =
                 RetryEngine.move_exhausted_issue_to_error_state(
                   "issue-refresh-held",
                   "MT-REFRESH-HELD",
                   {:issue_state_refresh_failed, {:aiur, :locally_held, %{resource: "core", reason: :shared_budget, reset_at: DateTime.utc_now()}}}
                 )
      end)
    end
  end

  describe "retry exhaustion terminal state (#2427)" do
    defp memory_tracker_for_retry do
      write_workflow_file!(Aiur.Workflow.workflow_file_path(),
        tracker_kind: "memory",
        opencode_command: System.find_executable("true")
      )

      Application.put_env(:aiur, :memory_tracker_recipient, self())
    end

    test "a transient exhaustion reason never stamps agent:error and schedules a re-claim" do
      memory_tracker_for_retry()

      # A closed socket and a DNS failure (the first cause the ticket names)
      # are both transient infrastructure faults. `:nxdomain` is the case that
      # actually fails without the AutoResume normalisation (#2427 review): it
      # is not in the provider-timeout whitelist, so the raw struct used to
      # classify as `nil` (claim released, no re-claim) even though the
      # terminal write was already suppressed.
      for reason <- [%Req.TransportError{reason: :closed}, %Req.TransportError{reason: :nxdomain}] do
        issue_id = "issue-transient-2427-#{inspect(reason.reason)}"
        identifier = "MT-TRANSIENT-#{inspect(reason.reason)}"

        final =
          RetryEngine.schedule_issue_retry(%State{}, issue_id, Config.max_retry_attempts() + 1, %{
            identifier: identifier,
            # Mirrors what handle_agent_down/3 records when the run exits on a
            # transport fault: the structured transient reason rides alongside
            # the formatted error string.
            error: "agent exited: #{inspect(reason)}",
            transient_reason: reason,
            delay_type: :failure
          })

        # A transient infrastructure fault: the terminal `agent:error` write
        # must never reach the tracker.
        refute_receive {:memory_tracker_state_update, ^identifier, "error"}, 200

        # The claim is released (give-up), but a bounded automatic re-claim is
        # scheduled so the ticket recovers once the cause clears. The cause is
        # pinned: the raw transport struct is normalised through the shared
        # classifier, so it is `:transient_tracker`, not the provider-timeout
        # whitelist (#2427 review finding 4).
        assert Map.has_key?(final.released_claims, issue_id)
        assert %{cause: :transient_tracker} = final.auto_resume[issue_id]
      end
    end

    test "a permanent exhaustion reason still stamps agent:error" do
      issue_id = "issue-permanent-2427"
      identifier = "MT-PERMANENT"
      memory_tracker_for_retry()

      RetryEngine.schedule_issue_retry(%State{}, issue_id, Config.max_retry_attempts() + 1, %{
        identifier: identifier,
        error: "agent exited: {:workspace_prepare_failed, :enoent}",
        transient_reason: {:workspace_prepare_failed, :enoent},
        delay_type: :failure
      })

      # A genuine agent failure is exactly where `agent:error` belongs.
      assert_receive {:memory_tracker_state_update, ^identifier, "error"}, 200
    end

    test "an advanced open PR head hands exhaustion to human review" do
      memory_tracker_for_retry()
      identifier = "MT-REWORK-EXHAUSTED"

      RetryEngine.schedule_issue_retry(%State{}, "issue-rework-exhausted", Config.max_retry_attempts() + 1, %{
        identifier: identifier,
        error: "agent exited: no-op continuation",
        rework_head_sha: "old-head",
        open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "new-head"}}} end,
        commit_ci_status_fetcher: fn _ ->
          {:ok, %{check_runs: [], commit_status: %{"state" => "success"}}}
        end,
        delay_type: :failure
      })

      assert_receive {:memory_tracker_state_update, ^identifier, "human-review"}, 200
      refute_receive {:memory_tracker_state_update, ^identifier, "error"}, 100
    end

    test "an advanced PR with pending checks hands exhaustion to ci-wait" do
      memory_tracker_for_retry()
      identifier = "MT-REWORK-CI-WAIT"

      RetryEngine.schedule_issue_retry(%State{}, "issue-rework-ci-wait", Config.max_retry_attempts() + 1, %{
        identifier: identifier,
        error: "agent exited: no-op continuation",
        rework_head_sha: "old-head",
        open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "new-head"}}} end,
        commit_ci_status_fetcher: fn _ ->
          {:ok, %{check_runs: [%{"status" => "queued", "conclusion" => nil}], commit_status: %{"state" => "pending"}}}
        end,
        delay_type: :failure
      })

      assert_receive {:memory_tracker_state_update, ^identifier, "ci-wait"}, 200
      refute_receive {:memory_tracker_state_update, ^identifier, "error"}, 100
    end

    test "a failed PR head lookup hands exhaustion to human review" do
      memory_tracker_for_retry()
      identifier = "MT-REWORK-PR-READ-FAILED"

      RetryEngine.schedule_issue_retry(%State{}, "issue-rework-pr-read-failed", Config.max_retry_attempts() + 1, %{
        identifier: identifier,
        error: "agent exited: no-op continuation",
        rework_head_sha: "old-head",
        open_pr_fetcher: fn _ -> {:error, :rate_limited} end,
        delay_type: :failure
      })

      assert_receive {:memory_tracker_state_update, ^identifier, "human-review"}, 200
      refute_receive {:memory_tracker_state_update, ^identifier, "error"}, 100
    end

    test "unknown CI status keeps exhausted pushed work in ci-wait" do
      memory_tracker_for_retry()
      identifier = "MT-REWORK-CI-READ-FAILED"

      RetryEngine.schedule_issue_retry(%State{}, "issue-rework-ci-read-failed", Config.max_retry_attempts() + 1, %{
        identifier: identifier,
        error: "agent exited: no-op continuation",
        rework_head_sha: "old-head",
        open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "new-head"}}} end,
        commit_ci_status_fetcher: fn _ -> {:error, :rate_limited} end,
        delay_type: :failure
      })

      assert_receive {:memory_tracker_state_update, ^identifier, "ci-wait"}, 200
      refute_receive {:memory_tracker_state_update, ^identifier, "error"}, 100
    end

    test "an unknown initial baseline conservatively hands exhausted rework to review" do
      memory_tracker_for_retry()
      identifier = "MT-REWORK-BASELINE-UNKNOWN"

      RetryEngine.schedule_issue_retry(%State{}, "issue-rework-baseline-unknown", Config.max_retry_attempts() + 1, %{
        identifier: identifier,
        error: "agent exited: no-op continuation",
        rework_head_sha: :lookup_failed,
        open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "same-head"}}} end,
        commit_ci_status_fetcher: fn _ ->
          {:ok, %{check_runs: [], commit_status: %{"state" => "success"}}}
        end,
        delay_type: :failure
      })

      assert_receive {:memory_tracker_state_update, ^identifier, "human-review"}, 200
      refute_receive {:memory_tracker_state_update, ^identifier, "error"}, 100
    end

    test "a nil baseline with an open PR on retry exhaustion hands off to CI wait" do
      memory_tracker_for_retry()
      identifier = "MT-REWORK-NIL-BASELINE"

      RetryEngine.schedule_issue_retry(%State{}, "issue-rework-nil-baseline", Config.max_retry_attempts() + 1, %{
        identifier: identifier,
        error: "agent exited: no-op continuation",
        rework_head_sha: nil,
        open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "existing-head"}}} end,
        commit_ci_status_fetcher: fn _ -> {:ok, %{check_runs: [%{"status" => "pending"}], commit_status: %{}}} end,
        delay_type: :failure
      })

      assert_receive {:memory_tracker_state_update, ^identifier, "ci-wait"}, 200
      refute_receive {:memory_tracker_state_update, ^identifier, "error"}, 100
    end

    test "an unchanged or missing PR head keeps exhaustion in error" do
      memory_tracker_for_retry()

      for {identifier, fetcher} <- [
            {"MT-REWORK-UNCHANGED", fn _ -> {:ok, %{"head" => %{"sha" => "same-head"}}} end},
            {"MT-REWORK-MISSING", fn _ -> {:ok, nil} end}
          ] do
        RetryEngine.schedule_issue_retry(%State{}, identifier, Config.max_retry_attempts() + 1, %{
          identifier: identifier,
          error: "agent exited: no-op continuation",
          rework_head_sha: "same-head",
          open_pr_fetcher: fetcher,
          delay_type: :failure
        })

        assert_receive {:memory_tracker_state_update, ^identifier, "error"}, 200
      end
    end
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)
end
