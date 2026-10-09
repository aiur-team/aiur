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
    assert Enum.sort(changed) == ~w(voice.stt voice.tts)

    for id <- changed do
      assert after_removal.capabilities[id] == %{state: :unavailable, reason: :not_configured}
    end

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
      assert report.capabilities["build_orders"] == %{state: :unknown, reason: :unknown}
      assert report.capabilities["build_orders.progress"] == %{state: :unknown, reason: :unknown}
      assert MapSet.member?(warnings, {:failed, Aiur.BuildOrder.CapabilityProvider})
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
    spec = Supervisor.child_spec({Bandit, plug: AiurWeb.Endpoint, port: 0}, id: {AiurWeb.Endpoint, :http})
    assert {:ok, _server} = Supervisor.start_child(AiurWeb.Endpoint, spec)
  end
end
