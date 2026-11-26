Code.require_file("fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.RetryEngine.LocalBudgetTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.State
  import Aiur.RetryEngineFixture, only: [seed_metadata: 0]

  describe "local budget retry polling" do
    test "three local holds preserve the claim and poll-failure budget" do
      issue_id = "issue-local-budget"

      initial = %State{
        claimed: MapSet.new([issue_id]),
        released_claims: %{},
        retry_attempts: %{}
      }

      hold = %{reason: :actor_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 3_600, :second)}

      # Thread each scheduled retry's metadata back in, exactly as the poll loop
      # does, so a regression that counts a local hold as a tracker failure
      # reaches the release threshold instead of quietly staying under it.
      final =
        Enum.reduce(1..3, {initial, seed_metadata()}, fn attempt, {state, metadata} ->
          next = RetryEngine.handle_retry_poll_failure(state, issue_id, attempt, metadata, {:aiur, :locally_held, hold})

          retry = next.retry_attempts[issue_id]
          Process.cancel_timer(retry.timer_ref)
          {next, retry}
        end)
        |> elem(0)

      assert MapSet.member?(final.claimed, issue_id)
      assert final.released_claims == %{}
      assert final.retry_attempts[issue_id].error =~ "retry poll locally held"
      assert final.retry_attempts[issue_id].retry_poll_failures == 0
    end

    # #2409 regression: older `Errors.classify_error` versions wrapped a held
    # GitHub request as `{:github, :transport, %{reason: {:aiur, :locally_held,
    # hold}}}`. #2429 now classifies it `{:github, :local_hold, ...}`, but the
    # legacy wrapper must still take the same non-consuming `:local_budget_hold`
    # retry as the raw form — otherwise three 30-second throttles exhaust the
    # retry budget and park the ticket in `agent:error` (the incident's
    # "released claim after 3 tracker failures").
    test "the transport-classified hold shape also preserves the claim and poll-failure budget" do
      issue_id = "issue-wrapped-local-budget"

      initial = %State{
        claimed: MapSet.new([issue_id]),
        released_claims: %{},
        retry_attempts: %{}
      }

      hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 30, :second)}
      wrapped = {:github, :transport, %{reason: {:aiur, :locally_held, hold}}}

      final =
        Enum.reduce(1..3, {initial, seed_metadata()}, fn attempt, {state, metadata} ->
          next = RetryEngine.handle_retry_poll_failure(state, issue_id, attempt, metadata, wrapped)

          retry = next.retry_attempts[issue_id]
          Process.cancel_timer(retry.timer_ref)
          {next, retry}
        end)
        |> elem(0)

      assert MapSet.member?(final.claimed, issue_id)
      assert final.released_claims == %{}
      assert final.retry_attempts[issue_id].error =~ "retry poll locally held"
      assert final.retry_attempts[issue_id].retry_poll_failures == 0
      assert final.retry_attempts[issue_id].attempt == 3
    end

    # #2429: `Errors.classify_error` now classifies a held request as
    # `{:github, :local_hold, %{reason: ..., hold: hold}}` — the shape a tracker
    # poll actually sees today. It must take the same non-consuming
    # `:local_budget_hold` retry as the raw form.
    test "the :local_hold shape also preserves the claim and poll-failure budget" do
      issue_id = "issue-local-hold-shape"

      initial = %State{
        claimed: MapSet.new([issue_id]),
        released_claims: %{},
        retry_attempts: %{}
      }

      hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 30, :second)}
      reason = {:github, :local_hold, %{reason: {:aiur, :locally_held, hold}, hold: hold}}

      final =
        Enum.reduce(1..3, {initial, seed_metadata()}, fn attempt, {state, metadata} ->
          next = RetryEngine.handle_retry_poll_failure(state, issue_id, attempt, metadata, reason)

          retry = next.retry_attempts[issue_id]
          Process.cancel_timer(retry.timer_ref)
          {next, retry}
        end)
        |> elem(0)

      assert MapSet.member?(final.claimed, issue_id)
      assert final.released_claims == %{}
      assert final.retry_attempts[issue_id].error =~ "retry poll locally held"
      assert final.retry_attempts[issue_id].retry_poll_failures == 0
      assert final.retry_attempts[issue_id].attempt == 3
    end

    # #2339: `ensure_tracker_preflight` surfaces a held preflight probe as
    # `{:github_auth_preflight_failed, %{classification: :local_hold, detail:
    # ...}}`. That shape must also take the non-consuming `:local_budget_hold`
    # retry, otherwise the follow-up poll after a hold-based agent-exit retry
    # counts the same hold as a tracker failure and releases the claim.
    test "the preflight-diagnostic hold shape also preserves the claim and poll-failure budget" do
      issue_id = "issue-preflight-hold"

      initial = %State{
        claimed: MapSet.new([issue_id]),
        released_claims: %{},
        retry_attempts: %{}
      }

      hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 30, :second)}

      reason =
        {:github_auth_preflight_failed, %{classification: :local_hold, detail: %{reason: {:aiur, :locally_held, hold}, hold: hold}}}

      final =
        Enum.reduce(1..3, {initial, seed_metadata()}, fn attempt, {state, metadata} ->
          next = RetryEngine.handle_retry_poll_failure(state, issue_id, attempt, metadata, reason)

          retry = next.retry_attempts[issue_id]
          Process.cancel_timer(retry.timer_ref)
          {next, retry}
        end)
        |> elem(0)

      assert MapSet.member?(final.claimed, issue_id)
      assert final.released_claims == %{}
      assert final.retry_attempts[issue_id].error =~ "retry poll locally held"
      assert final.retry_attempts[issue_id].retry_poll_failures == 0
      assert final.retry_attempts[issue_id].attempt == 3
    end

    test "a genuine tracker failure still counts and releases at exhaustion" do
      issue_id = "issue-tracker-failure"

      initial = %State{
        claimed: MapSet.new([issue_id]),
        released_claims: %{},
        retry_attempts: %{}
      }

      final =
        Enum.reduce(1..3, {initial, seed_metadata()}, fn attempt, {state, metadata} ->
          next = RetryEngine.handle_retry_poll_failure(state, issue_id, attempt, metadata, {:error, :bad_gateway})

          case next.retry_attempts[issue_id] do
            %{timer_ref: timer_ref} = retry when timer_ref != nil ->
              Process.cancel_timer(timer_ref)
              {next, retry}

            _released ->
              {next, metadata}
          end
        end)
        |> elem(0)

      refute MapSet.member?(final.claimed, issue_id)
      assert Map.has_key?(final.released_claims, issue_id)
    end
  end

  test "repeated broker timeouts retain the claim and both retry counters" do
    issue_id = "broker-timeout-claim"

    reasons = [
      :github_budget_broker_timeout,
      {:github, :timeout, %{reason: :github_budget_broker_timeout}},
      {:github, :local_hold, %{reason: :github_budget_broker_timeout}},
      {:workspace_github_connectivity_failed, "/workspace", {:github_auth_preflight_failed, %{classification: :local_hold, detail: %{reason: :github_budget_broker_timeout}}}}
    ]

    final =
      Enum.reduce(reasons ++ reasons, %State{claimed: MapSet.new([issue_id])}, fn reason, state ->
        metadata = %{identifier: "repo#2990", retry_poll_failures: 2}
        next = RetryEngine.handle_retry_poll_failure(state, issue_id, 2, metadata, reason)
        retry = next.retry_attempts[issue_id]
        assert retry.attempt == 2
        assert retry.retry_poll_failures == 2
        assert retry.delay_type == :local_budget_hold
        Process.cancel_timer(retry.timer_ref)
        next
      end)

    assert MapSet.member?(final.claimed, issue_id)
    refute Map.has_key?(final.released_claims, issue_id)
  end

  test "a broker timeout on agent exit preserves the dispatched attempt" do
    issue_id = "broker-exit"
    ref = make_ref()
    reason = {:workspace_github_connectivity_failed, "/workspace", {:github_auth_preflight_failed, %{classification: :local_hold, detail: %{reason: :github_budget_broker_timeout}}}}

    state = %State{
      running: %{issue_id => %{ref: ref, identifier: "repo#2990", started_at: DateTime.utc_now(), retry_attempt: 2}},
      claimed: MapSet.new([issue_id]),
      dispatch_recovery: %{workspace_ownership: %{waits: %{}, ready: %{}}, codex_thrash_budget: %{}}
    }

    assert {:noreply, next} = RetryEngine.handle_agent_down(state, ref, reason)
    retry = next.retry_attempts[issue_id]
    assert retry.attempt == 2
    assert retry.delay_type == :local_budget_hold
    assert MapSet.member?(next.claimed, issue_id)
    Process.cancel_timer(retry.timer_ref)
  end
end
