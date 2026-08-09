defmodule Aiur.GitHubAuthPreflightTest do
  use Aiur.TestSupport

  alias Aiur.{AlertFeed, Config.Paths}
  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.GitHub.Client
  alias Aiur.Orchestrator.{Dispatcher, State}

  defmodule FailingPreflightClient do
    def preflight_auth do
      {:error,
       {:github_auth_preflight_failed,
        %{
          reason: :invalid_or_expired_token,
          endpoint: :issues,
          repo: "owner/repo",
          token_source: "GITHUB_TOKEN",
          status: 401,
          gh_keyring_status: :available,
          message: "GitHub auth preflight failed for GITHUB_TOKEN while validating owner/repo issues access. Aiur uses GITHUB_TOKEN and it takes precedence over `gh` keyring auth."
        }}}
    end

    def fetch_candidate_issues do
      if pid = Application.get_env(:aiur, :github_auth_preflight_test_pid) do
        send(pid, :candidate_fetch_called)
      end

      {:ok, []}
    end
  end

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    Application.put_env(:aiur, :github_client_module, FailingPreflightClient)
    Application.put_env(:aiur, :github_auth_preflight_test_pid, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    on_exit(fn ->
      Application.delete_env(:aiur, :github_client_module)
      Application.delete_env(:aiur, :github_auth_preflight_test_pid)
      restore_env("GITHUB_TOKEN", prev_token)
    end)

    :ok
  end

  test "orchestrator stops before candidate polling when GitHub auth preflight fails" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.tracker.auth_preflight_failed")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    orchestrator_name = Module.concat(__MODULE__, :PreflightOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    log =
      capture_log(fn ->
        send(pid, :run_poll_cycle)
        # Barrier: a synchronous system message queues behind :run_poll_cycle,
        # so this returns only after the cycle (and its preflight Logger.error)
        # has been fully handled — deterministic vs. a fixed sleep.
        _ = :sys.get_state(pid)
      end)

    assert log =~ "GitHub auth preflight failed for GITHUB_TOKEN"
    assert log =~ "takes precedence over `gh` keyring auth"
    refute log =~ "test-gh-token"
    refute_received :candidate_fetch_called

    assert_receive {:event, %{topic: "system.tracker.auth_preflight_failed"} = event}, 500
    assert event["reason"] =~ "GitHub tracker authentication preflight failed"
    assert event["reason"] =~ "classification=invalid_or_expired_token"
    assert event["needs_attention"] == true
  end

  test "tracker auth fleet alert is deduplicated by stable cause and rearms after recovery" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.tracker.auth_preflight_failed")
    :ok = Exchange.subscribe("system.tracker.auth_preflight_failed.resolved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    {:error, {:github_auth_preflight_failed, diagnostic}} = FailingPreflightClient.preflight_auth()

    changed_diagnostic = Map.put(diagnostic, :message, "latest probe failed at a different endpoint")

    {:ok, results} =
      Agent.start_link(fn ->
        [
          {:error, {:github_auth_preflight_failed, diagnostic}},
          {:error, {:github_auth_preflight_failed, changed_diagnostic}},
          :ok,
          {:error, {:github_auth_preflight_failed, changed_diagnostic}}
        ]
      end)

    preflight_fun = scripted_preflight(results)

    first = Dispatcher.maybe_dispatch(%State{}, & &1, preflight_fun)
    assert first.tracker_preflight_alert_signature == "github-auth:invalid_or_expired_token:owner/repo"

    assert_receive {:event, %{topic: "system.tracker.auth_preflight_failed"} = first_event}, 500
    assert first_event["reason"] =~ "fleet dispatch is paused"
    assert first_event["reason"] =~ "expected to clear automatically"

    same_outage = Dispatcher.maybe_dispatch(first, & &1, preflight_fun)
    assert same_outage.tracker_preflight_alert_signature == first.tracker_preflight_alert_signature
    refute_receive {:event, %{topic: "system.tracker.auth_preflight_failed"}}, 100

    # A restarted orchestrator has no in-memory signature, but must still close
    # the persisted fleet attention when the first preflight succeeds.
    recovered = Dispatcher.maybe_dispatch(%State{}, & &1, preflight_fun)
    assert recovered.tracker_preflight_alert_signature == nil
    assert recovered.tracker_preflight_alert_resolution_emitted

    assert_receive {:event, %{topic: "system.tracker.auth_preflight_failed.resolved"}}, 500

    refute Enum.any?(AlertFeed.list(log_roots: [Paths.log_root_dir()], needs_attention: true), fn alert ->
             alert["topic"] == "system.tracker.auth_preflight_failed"
           end)

    rearmed = Dispatcher.maybe_dispatch(recovered, & &1, preflight_fun)
    assert rearmed.tracker_preflight_alert_signature == first.tracker_preflight_alert_signature

    assert_receive {:event, %{topic: "system.tracker.auth_preflight_failed"} = second_event}, 500
    assert second_event["reason"] =~ "latest probe failed at a different endpoint"

    assert Enum.any?(AlertFeed.list(log_roots: [Paths.log_root_dir()], needs_attention: true), fn alert ->
             alert["topic"] == "system.tracker.auth_preflight_failed"
           end)
  end

  test "missing GitHub token emits a fleet auth alert before polling" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.tracker.auth_preflight_failed")

    {:ok, results} = Agent.start_link(fn -> [{:error, :missing_github_token}] end)
    preflight_fun = scripted_preflight(results)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    state = Dispatcher.maybe_dispatch(%State{}, & &1, preflight_fun)
    assert state.tracker_preflight_alert_signature == "github-auth:missing_github_token"

    assert_receive {:event, %{topic: "system.tracker.auth_preflight_failed"} = event}, 500
    assert event["reason"] =~ "missing_github_token"
  end

  test "preflight formatter handles plain reasons for logging fallback" do
    assert Client.format_auth_preflight_error(:missing_github_token) == ":missing_github_token"
  end

  defp scripted_preflight(results) do
    &next_preflight_result(results, &1)
  end

  defp next_preflight_result(results, state) do
    Agent.get_and_update(results, &pop_preflight_result(&1, state))
  end

  defp pop_preflight_result([:ok | rest], state), do: {{:ok, state}, rest}

  defp pop_preflight_result([{:error, reason} | rest], state),
    do: {{:error, reason, state}, rest}
end
