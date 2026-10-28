defmodule Aiur.VoiceConversation.ComparisonTest do
  use Aiur.TestSupport

  alias Aiur.Config.Schema.VoiceConversation, as: Settings
  alias Aiur.VoiceConversation.{Comparison, Selection, Session}
  alias VoiceConverse.{Config, Events, SessionRegistry, TranscriptStore}
  alias VoiceConverse.Testing.{FakeBriefingSource, FakeProvider, StaticCredentials}

  defmodule Serializer do
    def encode!(message), do: message
  end

  setup do
    root = Aiur.TestSupport.tmp_root!("voice-comparison")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    %{root: root}
  end

  test "switches providers and models without altering briefing, tools or instance", %{root: root} do
    settings = %Settings{agent_id: "agent_test", llm: "eleven-model", cloud_disclosure_accepted: true}
    {:ok, config} = Aiur.VoiceConversation.build_config(settings, root)

    probe = fn provider, :probe ->
      send(self(), {:credential_probe, provider})
      {:ok, :present}
    end

    for {choice, model, wrapper} <- [{"elevenlabs_agents", "eleven-model", Aiur.VoiceConversation.Provider}, {"openai_realtime", "openai-model", Aiur.VoiceConversation.OpenAIProvider}] do
      assert {:ok, opts} = Selection.build_options(%{"provider" => choice, "model" => model}, settings, config, probe)
      assert {^wrapper, _} = opts[:provider]
      assert opts[:llm] == model
      assert opts[:comparison].provider == choice
      expected_provider = String.to_existing_atom(choice)
      assert_received {:credential_probe, ^expected_provider}
    end

    assert config.briefing_source == Aiur.VoiceConverse.Host.BriefingSource
    assert Enum.map(VoiceConverse.Tools.specs(config, :executor), & &1.name) == ["get_status", "get_details", "record_summary", "end_conversation"]
    assert {:error, :unconfigured} = Selection.build_options(%{"provider" => "unknown"}, settings, config, probe)
    assert {:error, :unconfigured} = Selection.build_options(%{"provider" => "openai_realtime", "model" => ""}, settings, config, probe)
    assert {:error, :unconfigured} = Selection.build_options(%{}, settings, config, fn _, _ -> {:error, :missing} end)
  end

  test "caps each provider across reservations and restarts; concurrent starts cannot oversubscribe", %{root: root} do
    reservations = 1..6 |> Enum.map(fn _ -> Task.async(fn -> Comparison.reserve(root, "openai_realtime", "test", 900) end) end) |> Enum.map(&Task.await(&1, :infinity))
    assert Enum.count(reservations, &match?({:ok, _}, &1)) == 3
    assert Enum.count(reservations, &(&1 == {:error, :cost_cap})) == 3
    assert {:error, :cost_cap} = Comparison.reserve(root, "openai_realtime", "test", 1)
    assert {:ok, row} = Comparison.reserve(root, "elevenlabs_agents", "test", 4000)
    assert row["reserved_seconds"] == 2700
    assert {:error, :cost_cap} = Comparison.reserve(root, "elevenlabs_agents", "test", 1)
    assert {:ok, %{meters: meters}} = Comparison.snapshot(root)
    assert Enum.find(meters, &(&1.provider == "openai_realtime")).used_seconds == 2700
    assert Enum.find(meters, &(&1.provider == "elevenlabs_agents")).used_seconds == 2700
  end

  test "remaining allowance bounds the next session and completed lines retain rating without audio", %{root: root} do
    assert {:ok, row} = Comparison.reserve(root, "openai_realtime", "chosen", 2700)
    assert :ok = Comparison.finish(root, row["id"], "session-one", 2_699_000, 412)
    assert {:ok, next} = Comparison.reserve(root, "openai_realtime", "chosen", 180)
    assert next["reserved_seconds"] == 1
    assert :ok = Comparison.rate(root, row["id"], 4, "Clear voice; Bearer abcdefgh12345")
    assert {:error, :invalid_rating} = Comparison.rate(root, row["id"], 6, "bad")
    assert {:error, :not_found} = Comparison.rate(root, "missing", 5, "")
    assert {:ok, %{rows: [saved, _]}} = Comparison.snapshot(root)
    assert saved["first_audio_ms"] == 412
    assert saved["model"] == "chosen"
    assert saved["minutes"] == 2699 / 60
    assert_in_delta saved["estimated_cost_usd"], 2699 / 2700 * 8, 0.00001
    assert saved["rating"] == 4
    assert saved["note"] =~ "[redacted]"
    refute Map.has_key?(saved, "audio")
    refute Jason.encode!(saved) =~ "abcdefgh12345"
  end

  test "corrupt comparison usage fails closed", %{root: root} do
    File.mkdir_p!(root)
    File.write!(Path.join(root, "comparison.json"), "broken")
    assert {:error, :comparison_unavailable} = Comparison.reserve(root, "openai_realtime", "test", 60)
    assert {:error, :comparison_unavailable} = Comparison.snapshot(root)
  end

  test "comparison channel lists durable lines and records ratings through the host settings", %{root: root} do
    previous = Application.get_env(:aiur, :conversation_state_dir)
    Application.put_env(:aiur, :conversation_state_dir, root)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :conversation_state_dir, previous), else: Application.delete_env(:aiur, :conversation_state_dir)
    end)

    assert {:error, :unconfigured} = Selection.options(%{"provider" => "unknown"})
    assert {:ok, %{rows: []}} = Selection.snapshot()
    voice_root = Path.join(root, "voice")
    assert {:ok, row} = Comparison.reserve(voice_root, "openai_realtime", "chosen", 60)
    assert :ok = Comparison.finish(voice_root, row["id"], "session", 30_000, 200)
    socket = %Phoenix.Socket{topic: "voice:executor_receipts", joined: true, transport_pid: self(), serializer: Serializer}
    channel = AiurWeb.ExecutorVoiceReceiptChannel
    assert {:noreply, ^socket} = channel.handle_in("comparison_list", %{}, socket)
    assert_received %Phoenix.Socket.Message{event: "comparison", payload: %{rows: [listed]}}
    assert listed["model"] == "chosen"
    payload = %{"id" => row["id"], "rating" => 5, "note" => "Preferred voice"}
    assert {:noreply, ^socket} = channel.handle_in("comparison_rate", payload, socket)
    assert_received %Phoenix.Socket.Message{event: "comparison", payload: %{rows: [rated]}}
    assert rated["rating"] == 5
    assert rated["note"] == "Preferred voice"
    assert {:ok, %{rows: [^rated]}} = Selection.snapshot()
    assert {:noreply, ^socket} = channel.handle_in("comparison_rate", %{payload | "rating" => 0}, socket)
    assert_received %Phoenix.Socket.Message{event: "comparison_error", payload: %{reason: reason}}
    assert reason =~ "Rating could not be saved"
    File.write!(Path.join(voice_root, "comparison.json"), "broken")
    assert {:noreply, ^socket} = channel.handle_in("comparison_list", %{}, socket)
    assert_received %Phoenix.Socket.Message{event: "comparison_error", payload: %{reason: unavailable}}
    assert unavailable =~ "usage is unavailable"
  end

  test "session refuses the cap before calling the provider double", %{root: root} do
    assert {:ok, _} = Comparison.reserve(root, "openai_realtime", "test", 2700)
    test_pid = self()
    start = fn _, _ -> send(test_pid, :provider_started) end
    spec = %{root: root, provider: "openai_realtime", model: "test", max_seconds: 60}
    assert {:error, :cost_cap} = Session.start(self(), start_session: start, comparison: spec)
    refute_received :provider_started
  end

  test "a session without audio retains unavailable latency", %{root: root} do
    assert {:ok, row} = Comparison.reserve(root, "elevenlabs_agents", "test", 60)
    assert :ok = Comparison.finish(root, row["id"], "silent-session", 10_000, nil)
    assert {:ok, %{rows: [saved]}} = Comparison.snapshot(root)
    assert saved["first_audio_ms"] == nil
    assert saved["minutes"] == 10 / 60
  end

  test "provider double records first audio and chosen model beside the real transcript", %{root: root} do
    instance = Module.concat(__MODULE__, "Instance#{System.unique_integer([:positive])}")
    clock = start_supervised!({Agent, fn -> 1_000 end})

    {:ok, config} =
      Config.new(name: instance, transcript_root: root, credentials: StaticCredentials, briefing_source: FakeBriefingSource, provider: FakeProvider, llm: "old", cloud_disclosure_accepted: true)

    start_supervised!(VoiceConverse.child_spec(config))
    start = fn owner, opts -> VoiceConverse.start_session(instance, %{id: "executor"}, Keyword.put(opts, :client, owner)) end
    deliver = fn _, _, _ -> {:ok, %{id: 42}} end

    opts = [
      instance: instance,
      start_session: start,
      deliver: deliver,
      llm: "session-model",
      provider: {FakeProvider, [script: []]},
      comparison: %{root: root, provider: "openai_realtime", model: "session-model", max_seconds: 30, clock: fn -> Agent.get(clock, & &1) end}
    ]

    assert {:ok, wrapper, id} = Session.start(self(), opts)
    ref = Process.monitor(wrapper)
    {:ok, core} = SessionRegistry.lookup(instance, id)
    assert :sys.get_state(core).config.llm == "session-model"
    assert :sys.get_state(core).config.limits.max_session_seconds == 30
    Agent.update(clock, fn _ -> 1_420 end)
    FakeProvider.emit(:sys.get_state(core).provider_ref, %Events.AgentAudio{data_b64: "AAAA", format: :pcm_16000, turn_id: "first"})
    receive_barrier({:executor_voice, %Events.AgentAudio{}})
    # The forwarded audio reaches this process before record/2 runs; cross the session barrier.
    :sys.get_state(wrapper)
    Agent.update(clock, fn _ -> 2_000 end)
    # Drive the actual cap message instead of waiting on wall time.
    send(wrapper, :comparison_cap)
    receive_barrier({:executor_voice, {:comparison_saved, token}})
    receive_barrier({:DOWN, ^ref, :process, ^wrapper, :normal})
    assert {:ok, %{rows: [row]}} = Comparison.snapshot(root)
    assert row["id"] == token
    assert row["session_id"] == id
    assert row["provider"] == "openai_realtime"
    assert row["model"] == "session-model"
    assert row["first_audio_ms"] == 420
    assert row["seconds"] == 1.0
    assert row["status"] == "ended"
    assert {:ok, records, _} = TranscriptStore.read(root, id)
    assert hd(records)["model"] == "session-model"
    assert :ok = Comparison.rate(root, token, 5, "Preferred")
  end
end
