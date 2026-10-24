defmodule Aiur.Orchestrator.CiReadinessGateTest do
  use Aiur.TestSupport, async: false

  alias Aiur.CodeHost
  alias Aiur.Orchestrator.{CiReadinessGate, Dispatcher, State}

  defmodule Provider do
    @behaviour Aiur.CodeHost.CiReadiness
    @impl true
    def retryable_error?(:custom_transient), do: true
    def retryable_error?(_), do: false
    @impl true
    def error_message(reason), do: "custom: #{reason}"
    @impl true
    def check_fun, do: fn _ -> {:error, :custom_transient} end
    @impl true
    def readiness_scope(_), do: :custom_scope
    @impl true
    def cached_result(_), do: :unavailable
    @impl true
    def cache_result(result) do
      send(self(), {:cached, result})
      :ok
    end

    @impl true
    def format(_), do: "custom readiness"
    @impl true
    def unavailable(branch, reason), do: %{ready?: false, base_branch: branch, issues: [reason]}
  end

  defmodule Tracker do
    def fetch_candidate_issues, do: {:error, :test_unavailable}
    def code_host, do: __MODULE__
    def ci_readiness, do: Provider
    def with_poll_cycle(_fun), do: throw(:poll_cycle_boundary)
    def format_preflight_error(_reason), do: "custom preflight"
  end

  setup do
    adapters = Application.fetch_env!(:aiur, :tracker_adapters)
    Application.put_env(:aiur, :tracker_adapters, Map.put(adapters, "custom", Tracker))
    on_exit(fn -> Application.put_env(:aiur, :tracker_adapters, adapters) end)
    :ok
  end

  test "a tracker without a provider marks readiness checked without starting work or emitting" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    check = fn _ -> flunk("no readiness provider") end
    emit = fn _, _ -> flunk("no readiness alert") end

    assert CodeHost.ci_readiness() == nil

    assert %{ci_readiness_checked: true, ci_readiness_check_pid: nil, ci_readiness_result: nil} =
             CiReadinessGate.start_initial_ci_readiness_check(%State{}, "memory", "main", check)

    assert %{ci_readiness_checked: true, ci_readiness_result: nil} =
             CiReadinessGate.check_initial_ci_readiness(%State{}, "memory", "main", check, emit)

    assert %{ci_readiness_checked: true, ci_readiness_check_pid: nil} = CiReadinessGate.maybe_warn_ci_readiness(%State{})
  end

  # Characterization of the unchanged rate-limit delay; guards future regressions.
  test "rate-limited retry waits retry_after seconds" do
    before = System.monotonic_time(:millisecond)
    error = {:github, :rate_limited, %{retry_after: 7}}
    state = CiReadinessGate.check_initial_ci_readiness(%State{}, "github", "main", fn _ -> {:error, error} end, fn _, _ -> :ok end)
    after_ms = System.monotonic_time(:millisecond)

    refute state.ci_readiness_checked
    assert state.ci_readiness_retry_at_ms >= before + 7_000
    assert state.ci_readiness_retry_at_ms <= after_ms + 7_000
  end

  test "explicit kind selects provider classification and formatting independently of configured tracker" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    emit = fn topic, opts -> send(self(), {:alert, topic, opts}) end
    state = CiReadinessGate.check_initial_ci_readiness(%State{}, "custom", "main", Provider.check_fun(), emit)

    refute state.ci_readiness_checked
    assert state.ci_readiness_unavailable_alerted
    assert is_integer(state.ci_readiness_retry_at_ms)
    assert_received {:alert, "system.ci_readiness.unavailable", opts}
    assert opts[:reason] == "custom: custom_transient"
    refute_received {:cached, _}
  end

  test "configured provider drives scope, async checks and retry results" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "custom")
    assert CodeHost.ci_readiness() == Provider
    state = CiReadinessGate.maybe_warn_ci_readiness(%State{})
    assert state.ci_readiness_scope == :custom_scope
    token = state.ci_readiness_check_token
    receive_barrier({:ci_readiness_result, ^token, result})
    state = CiReadinessGate.handle_ci_readiness_result(state, token, result)
    refute state.ci_readiness_checked
    assert state.ci_readiness_check_pid == nil
    assert is_integer(state.ci_readiness_retry_at_ms)
  end

  test "async results and timeouts retain the explicitly selected provider" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    readiness = %{ready?: true}
    state = CiReadinessGate.start_initial_ci_readiness_check(%State{}, "custom", "main", fn _ -> {:ok, readiness} end)
    token = state.ci_readiness_check_token
    receive_barrier({:ci_readiness_result, ^token, result})
    completed = CiReadinessGate.handle_ci_readiness_result(state, token, result)
    assert completed.ci_readiness_checked
    assert completed.ci_readiness_result == readiness
    assert completed.ci_readiness_check_provider == nil
    assert_received {:cached, ^readiness}

    pending = CiReadinessGate.start_initial_ci_readiness_check(%State{}, "custom", "main", Provider.check_fun())
    token = pending.ci_readiness_check_token
    receive_barrier({:ci_readiness_result, ^token, _result})
    timed_out = CiReadinessGate.handle_ci_readiness_timeout(pending, token)
    refute timed_out.ci_readiness_checked
    assert timed_out.ci_readiness_unavailable_alerted
    assert is_integer(timed_out.ci_readiness_retry_at_ms)
  end

  test "dispatcher opens its tracker poll-cycle boundary" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "custom")
    assert catch_throw(Dispatcher.maybe_dispatch(%State{})) == :poll_cycle_boundary
  end

  test "tracker facade uses optional preflight formatter and safe defaults" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "custom")
    assert Aiur.Tracker.format_preflight_error(:failure) == "custom preflight"
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    assert Aiur.Tracker.format_preflight_error(:failure) == ":failure"
    assert Aiur.Tracker.with_poll_cycle(fn -> :ran end) == :ran
  end
end
