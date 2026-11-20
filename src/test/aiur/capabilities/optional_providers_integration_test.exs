defmodule Aiur.Capabilities.OptionalProvidersIntegrationTest do
  use Aiur.TestSupport
  alias Aiur.Capabilities.Collector
  alias Aiur.Webhooks.{DeliveryMode, ModeTable}

  test "registered providers describe no-dashboard runs without claiming optional HTTP operations" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "linear")
    previous = Application.get_env(:aiur, :no_dashboard, false)
    Application.put_env(:aiur, :no_dashboard, true)
    on_exit(fn -> Application.put_env(:aiur, :no_dashboard, previous) end)
    {report, warnings} = Collector.collect([])
    caps = report.capabilities
    assert caps["build_orders"] == %{state: :unavailable, reason: :unsupported_tracker}
    assert caps["build_orders.progress"] == %{state: :unavailable, reason: :dependency_unavailable, depends_on: ["build_orders"]}
    assert caps["webhook_ingress"] == %{state: :unavailable, reason: :not_configured}
    assert caps["remote_control"] == %{state: :unavailable, reason: :disabled}

    for id <- ~w(voice.stt voice.tts streamdeck conversations.read) do
      assert caps[id] == %{state: :unavailable, reason: :dependency_unavailable, depends_on: ["api.http"]}
    end

    refute caps["accounting.meters"].reason == :not_installed
    refute Enum.any?(warnings, &match?({:failed, _}, &1))
  end

  test "removing the voice key changes only voice IDs in the full registered report" do
    bind_http()
    path = Aiur.Workflow.workflow_file_path()
    write_workflow_file!(path, tracker_kind: "linear")
    base = File.read!(path)
    write_voice(path, base, "test-voice-secret")
    {before, _warnings} = Collector.collect([])
    assert before.capabilities["voice.stt"] == %{state: :available}
    assert before.capabilities["voice.tts"] == %{state: :available}
    write_voice(path, base, "")
    {after_removal, _warnings} = Collector.collect([])
    changed = for {id, entry} <- before.capabilities, entry != after_removal.capabilities[id], do: id
    assert Enum.sort(changed) == ~w(voice.conversation voice.stt voice.tts)

    for id <- ~w(voice.stt voice.tts) do
      assert after_removal.capabilities[id] == %{state: :unavailable, reason: :not_configured}
    end

    missing_key_reason = "ElevenLabs Agents skipped: elevenlabs.api_key / ELEVENLABS_API_KEY missing"
    refute before.capabilities["voice.conversation"].provider_reason =~ missing_key_reason
    assert after_removal.capabilities["voice.conversation"].provider_reason =~ missing_key_reason

    refute Jason.encode!(before) =~ "test-voice-secret"
  end

  test "repeated registry ticks never queue calls to a projection that never replies" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "test-owner/slow-catalog")
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.BuildOrder.GraphProjection)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, Aiur.BuildOrder.GraphProjection) end)

    pid =
      spawn_link(fn ->
        receive do
          :stop -> :ok
        end
      end)

    Process.register(pid, Aiur.BuildOrder.GraphProjection)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    for _tick <- 1..10 do
      {report, warnings} = Collector.collect(providers: [Aiur.BuildOrder.CapabilityProvider])
      assert %{state: :unknown, reason: :unknown, detail: detail} = report.capabilities["build_orders"]
      assert detail =~ "snapshot_unpublished"
      assert %{state: :unknown, reason: :unknown} = report.capabilities["build_orders.progress"]
      assert Enum.any?(warnings, &match?({:failed, Aiur.BuildOrder.CapabilityProvider, _}, &1))
    end

    assert {:message_queue_len, 0} = Process.info(pid, :message_queue_len)
    ref = Process.monitor(pid)
    send(pid, :stop)
    receive_barrier({:DOWN, ^ref, :process, ^pid, :normal})
  end

  test "ModeTable reads the full struct with normalized repository keys and ingress consumes it" do
    repo = "test-owner/optional-capability-mode-#{System.unique_integer([:positive])}"
    on_exit(fn -> ModeTable.delete(repo) end)
    assert ModeTable.mode(repo) == nil
    mode = %DeliveryMode{repo: repo, state: :configured_unproven, configured?: true}
    ModeTable.put(String.upcase(repo), mode)
    assert ModeTable.mode("  #{repo}  ") == mode
    context = %{settings: %{tracker: %{kind: "github", github: %{repo: repo}}}}
    assert Aiur.Webhooks.CapabilityProvider.capabilities(context) == %{"webhook_ingress" => %{state: :degraded, reason: :unknown}}
    assert ModeTable.transport(repo) == :polling
    ModeTable.delete(repo)
    assert ModeTable.mode(repo) == nil
  end

  defp write_voice(path, base, key) do
    File.write!(path, base <> "\nelevenlabs:\n  api_key: #{inspect(key)}\n  voice_id: test-voice-id\n")
    assert :ok = Aiur.WorkflowStore.force_reload()
  end

  defp bind_http do
    previous_shape = Application.get_env(:aiur, :no_dashboard, false)
    previous_config = Application.fetch_env!(:aiur, AiurWeb.Endpoint)
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.HttpServer)
    Application.put_env(:aiur, :no_dashboard, false)
    Application.put_env(:aiur, AiurWeb.Endpoint, Keyword.put(previous_config, :server, false))

    on_exit(fn ->
      Application.put_env(:aiur, :no_dashboard, previous_shape)
      Application.put_env(:aiur, AiurWeb.Endpoint, previous_config)
      Supervisor.restart_child(Aiur.Supervisor, Aiur.HttpServer)
    end)

    Aiur.TestSupport.start_owned_endpoint!()
    assert Application.fetch_env!(:aiur, AiurWeb.Endpoint)[:server] == false
    spec = Supervisor.child_spec({Bandit, plug: AiurWeb.Endpoint, port: 0}, id: {AiurWeb.Endpoint, :http})
    assert {:ok, _server} = Supervisor.start_child(AiurWeb.Endpoint, spec)
  end
end

defmodule Aiur.Capabilities.CollectorFailureTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Capabilities.Collector

  defmodule RaisingProvider do
    def capability_ids, do: ["test.failure"]
    def capabilities(_context), do: raise(ArgumentError, "provider exploded")
  end

  defmodule RetryProvider do
    def capability_ids, do: ["test.failure"]

    def capabilities(_context) do
      send(Application.fetch_env!(:aiur, :collector_failure_test_parent), {:provider_attempt, self()})

      receive do
        {:reply, result} -> result
      end
    end
  end

  defmodule BlockingProvider do
    def capability_ids, do: ["test.failure"]

    def capabilities(_context) do
      send(Application.fetch_env!(:aiur, :collector_failure_test_parent), {:blocking_attempt, self()})

      receive do
        :never -> %{}
      end
    end
  end

  test "records provider exception class and message in the warning and capability entry" do
    {report, warnings} = Collector.collect(providers: [RaisingProvider], boot_elapsed_ms_fun: fn -> 60_000 end)
    assert %{state: :unknown, reason: :unknown, detail: detail} = report.capabilities["test.failure"]
    assert detail =~ "ArgumentError"
    assert detail =~ "provider exploded"
    assert Enum.any?(warnings, &match?({:failed, RaisingProvider, ^detail}, &1))
  end

  test "retries one provider that exceeds its initial boot timeout" do
    Application.put_env(:aiur, :collector_failure_test_parent, self())
    on_exit(fn -> Application.delete_env(:aiur, :collector_failure_test_parent) end)
    collector = Task.async(fn -> Collector.collect(providers: [RetryProvider], timeout_ms: 25, boot_elapsed_ms_fun: fn -> 0 end) end)

    receive_barrier({:provider_attempt, _first})
    receive_barrier({:provider_attempt, second})
    send(second, {:reply, %{"test.failure" => %{state: :available}}})
    {report, warnings} = Task.await(collector, 1_000)
    assert report.capabilities["test.failure"] == %{state: :available}
    refute Enum.any?(warnings, &match?({:failed, RetryProvider, _}, &1))
  end

  test "records timeout duration when provider exceeds the collection window" do
    Application.put_env(:aiur, :collector_failure_test_parent, self())
    on_exit(fn -> Application.delete_env(:aiur, :collector_failure_test_parent) end)
    {report, warnings} = Collector.collect(providers: [BlockingProvider], timeout_ms: 20, boot_elapsed_ms_fun: fn -> 60_000 end)
    receive_barrier({:blocking_attempt, _pid})
    assert %{detail: "timed out after " <> elapsed} = report.capabilities["test.failure"]
    assert String.ends_with?(elapsed, " ms")
    assert Enum.any?(warnings, &match?({:failed, BlockingProvider, "timed out after " <> _}, &1))
  end
end
