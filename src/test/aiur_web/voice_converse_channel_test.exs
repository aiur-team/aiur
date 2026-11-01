defmodule AiurWeb.VoiceConverseChannelTest do
  # Keep the channel lifecycle cases together: each owns an isolated core instance and endpoint overrides.
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.{Endpoint, FinancialDataAccess, VoiceSessionLimiter, VoiceSocket}
  alias VoiceConverse.{Config, Events, TranscriptStore}
  alias VoiceConverse.Testing.{FakeProvider, StaticCredentials}
  @endpoint Endpoint

  defmodule Briefing do
    @behaviour VoiceConverse.Ports.BriefingSource
    @impl true
    def describe_target(_), do: %{id: "test-target", kind: :executor, title: "Test"}
    @impl true
    def brief(_), do: {:ok, %VoiceConverse.Briefing{}}
    @impl true
    def details(_, _, _), do: {:ok, ""}
    @impl true
    def sections(_), do: []
    @impl true
    def subscribe(_, _), do: :unsupported
    @impl true
    def alive?(_), do: true
  end

  defmodule AgentChannel do
    @behaviour VoiceConverse.Ports.AgentChannel
    @impl true
    def capabilities(_), do: %{fork: :none, instruct: true}
    @impl true
    def subscribe(_, _), do: :unsupported
    @impl true
    def instruct(_, "edited", key, _), do: {:ok, key}
    def instruct(_, _, _, _), do: {:error, :wrong_text}
    @impl true
    def ask(_, _, _, _), do: {:error, :unsupported}
    @impl true
    def fork_query(_, _, _), do: {:error, :unsupported}
  end

  setup do
    Process.flag(:trap_exit, true)
    Aiur.TestSupport.ensure_pubsub_running()
    Aiur.TestSupport.start_owned_endpoint!()
    if is_nil(Process.whereis(FinancialDataAccess.Generation)), do: start_supervised!(FinancialDataAccess.Generation)
    if is_nil(Process.whereis(VoiceSessionLimiter)), do: start_supervised!(VoiceSessionLimiter)
    name = Module.concat(__MODULE__, "Instance#{System.unique_integer([:positive])}")
    root = Path.join(System.tmp_dir!(), "converse-channel-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    StaticCredentials.put(%{fake: "test-secret"})
    EndpointStubs.put(dashboard_writable: true, voice_converse_instance: name, capabilities_report_fun: &report/0)
    %{name: name, root: root}
  end

  test "joined clients receive durable transcripts, assistant text and split audio", ctx do
    start_core(ctx)
    assert {:ok, %{conversation_id: id}, joined} = subscribe_and_join(client(), "voice:converse", payload())
    assert_push("state", %{"state" => "connecting"})
    assert_push("state", %{"state" => "listening"})
    provider = provider(ctx.name, id)
    FakeProvider.emit(provider, %Events.UserTranscript{text: "hello", final?: true})
    assert_push("transcript", %{"kind" => "final", "text" => "hello"})
    assert {:ok, records, _} = TranscriptStore.read(ctx.root, id)
    assert Enum.any?(records, &(&1["type"] == "user_turn" and &1["text"] == "hello"))
    FakeProvider.emit(provider, %Events.AgentText{turn_id: "one", text: "reply", final?: true})
    assert_push("assistant_text", %{"turn_id" => "one", "text" => "reply", "final" => true})
    pcm = :binary.copy(<<1, 2>>, 70_000)
    FakeProvider.emit(provider, %Events.AgentAudio{turn_id: "one", format: :pcm_24000, data_b64: Base.encode64(pcm)})
    assert_push("audio", %{"data" => first, "format" => "pcm_24000"})
    assert_push("audio", %{"data" => second, "format" => "pcm_24000"})
    assert byte_size(Base.decode64!(first)) == 131_072
    assert Base.decode64!(first) <> Base.decode64!(second) == pcm
    FakeProvider.emit(provider, %Events.Interruption{turn_id: "one"})
    assert_push("interrupted", %{"turn_id" => "one"})
    push(joined, "end", %{})
    assert_push("audio_done", %{}, 2_000)
    assert_push("ended", %{"reason" => "user_end"}, 2_000)
    assert_push("state", %{"state" => "ended"}, 2_000)
  end

  test "privacy preflight refusal releases the lease", ctx do
    start_core(ctx, preflight_error: Events.Error.new(:privacy_preflight_failed, "privacy"))

    for _ <- 1..3 do
      assert {:error, %{reason_code: "privacy_preflight_failed"}} = subscribe_and_join(client(), "voice:converse", payload())
    end
  end

  test "a stale authentication generation refuses the join before starting a session", ctx do
    start_core(ctx)
    current = client()
    authority = current.assigns.voice_authority
    stale = Phoenix.Socket.assign(current, :voice_authority, %{authority | configuration_generation: "stale-" <> authority.configuration_generation})

    for _ <- 1..3 do
      assert {:error, %{reason_code: "auth_changed"}} = subscribe_and_join(stale, "voice:converse", payload())
    end

    assert DynamicSupervisor.count_children(VoiceConverse.SessionSupervisor.name(ctx.name)).active == 0
    assert :sys.get_state(VoiceSessionLimiter).leases == %{}

    for id <- ["first", "second"] do
      assert {:ok, _, _} = subscribe_and_join(current, "voice:converse", Map.put(payload(), "client_session_id", id))
    end
  end

  test "a stopped agent cannot be a converse target", ctx do
    start_core(ctx)
    previous = Application.fetch_env(:aiur, :voice_target_resolver)
    Application.put_env(:aiur, :voice_target_resolver, AiurWeb.OperatorControlCenter.VoiceTargetResolver)
    on_exit(fn -> restore(:voice_target_resolver, previous) end)
    EndpointStubs.put(voice_target_payload_fun: fn -> %{fleet: %{running: []}} end)
    request = Map.put(payload(), "target", %{"kind" => "worker", "ticket" => "stopped"})
    assert {:error, %{reason_code: "target_not_found"}} = subscribe_and_join(client(), "voice:converse", request)
    assert DynamicSupervisor.count_children(VoiceConverse.SessionSupervisor.name(ctx.name)).active == 0
  end

  test "a running worker resolves to its typed host target", ctx do
    start_core(ctx)
    previous = Application.fetch_env(:aiur, :voice_target_resolver)
    Application.put_env(:aiur, :voice_target_resolver, AiurWeb.OperatorControlCenter.VoiceTargetResolver)
    on_exit(fn -> restore(:voice_target_resolver, previous) end)
    identity = %Aiur.TrackerIdentity{identifier: "4142"}

    EndpointStubs.put(
      voice_target_payload_fun: fn -> %{fleet: %{running: [%{issue_identifier: "4142"}]}} end,
      voice_converse_snapshot_fun: fn -> %{running: [%{identifier: "4142", tracker_identity: identity}]} end
    )

    request = Map.put(payload(), "target", %{"kind" => "worker", "ticket" => "4142"})
    assert {:ok, %{conversation_id: id}, _} = subscribe_and_join(client(), "voice:converse", request)
    {:ok, session} = VoiceConverse.SessionRegistry.lookup(ctx.name, id)
    assert %Aiur.VoiceConverse.Host.Worker{identity: ^identity} = :sys.get_state(session).target
  end

  test "invalid joins and unavailable capabilities refuse capture", ctx do
    start_core(ctx)
    assert {:error, %{reason_code: "invalid_payload"}} = subscribe_and_join(client(), "voice:converse", %{})
    assert {:error, %{reason_code: "invalid_payload"}} = subscribe_and_join(client(), "voice:converse", Map.put(payload(), "mode", "dictate"))
    EndpointStubs.put(capabilities_report_fun: fn -> put_in(report(), [:capabilities, "voice.conversation"], %{state: :unavailable, reason: :unconfigured}) end)
    assert {:error, %{reason_code: "unconfigured"}} = subscribe_and_join(client(), "voice:converse", payload())
    EndpointStubs.put(capabilities_report_fun: fn -> put_in(report(), [:capabilities, "voice.conversation"], %{state: :unknown, reason: :not_running}) end)
    assert {:error, %{reason_code: "unknown", reasons: [:not_running]}} = subscribe_and_join(client(), "voice:converse", payload())
  end

  test "audio, text, playback and malformed frames use the session APIs", ctx do
    start_core(ctx)
    assert {:ok, %{conversation_id: id}, joined} = subscribe_and_join(client(), "voice:converse", payload())
    assert_push("state", %{"state" => "listening"})
    provider = provider(ctx.name, id)
    pcm = Base.encode64(<<1, 2, 3, 4>>)
    push(joined, "audio", %{"data" => pcm})
    push(joined, "client_text", %{"text" => "typed turn"})
    assert_push("transcript", %{"text" => "typed turn", "kind" => "final"})
    assert {:send_user_text, "typed turn"} in FakeProvider.calls(provider)
    assert {:push_audio, pcm} in FakeProvider.calls(provider)
    push(joined, "audio", %{"data" => String.duplicate("A", 350_000)})
    assert_push("error", %{"reason_code" => "chunk_too_large"})
    push(joined, "audio", %{"data" => "invalid!"})
    assert_push("error", %{"reason_code" => "invalid_payload"})
    push(joined, "confirm_draft", %{"draft_id" => 123})
    assert_push("error", %{"reason_code" => "invalid_payload"})
    push(joined, "playback_state", %{"state" => "playing"})
    push(joined, "playback_state", %{"state" => "bad"})
    assert_push("error", %{"reason_code" => "invalid_payload"})
    {:ok, session} = VoiceConverse.SessionRegistry.lookup(ctx.name, id)
    assert :sys.get_state(session).playback_state == "playing"
  end

  test "same authenticated client reattaches during transport grace", ctx do
    start_core(ctx)
    assert {:ok, %{conversation_id: id}, joined} = subscribe_and_join(client(), "voice:converse", payload())
    assert_push("state", %{"state" => "listening"})
    ref = leave(joined)
    assert_reply(ref, :ok)
    assert {:ok, %{conversation_id: ^id}, _} = subscribe_and_join(client(), "voice:converse", payload())
    assert_push("state", %{"state" => "listening"})
    assert DynamicSupervisor.count_children(VoiceConverse.SessionSupervisor.name(ctx.name)).active == 1
    assert {:ok, %{conversation_id: other}, _} = subscribe_and_join(client("other"), "voice:converse", payload())
    refute other == id
  end

  test "last transport leaving persists transport_lost after grace", ctx do
    start_core(ctx)
    assert {:ok, %{conversation_id: id}, joined} = subscribe_and_join(client(), "voice:converse", payload())
    {:ok, session} = VoiceConverse.SessionRegistry.lookup(ctx.name, id)
    # Phoenix replies to leave before terminate/2 unsubscribes from the session.
    channel_monitor = Process.monitor(joined.channel_pid)
    ref = leave(joined)
    assert_reply(ref, :ok)
    assert_receive {:DOWN, ^channel_monitor, :process, _, _}, 2_000
    state = :sys.get_state(session)
    assert map_size(state.subscribers) == 0
    assert is_reference(state.transport_token)
    monitor = Process.monitor(session)
    send(session, {:transport_grace, state.transport_token})
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 2_000
    assert {:ok, records, _} = TranscriptStore.read(ctx.root, id)
    assert Enum.any?(records, &(&1["type"] == "session_ended" and &1["reason"] == "transport_lost"))
  end

  test "auth rotation ends the session without reconnect grace", ctx do
    start_core(ctx)
    assert {:ok, %{conversation_id: id}, joined} = subscribe_and_join(client(), "voice:converse", payload())
    {:ok, session} = VoiceConverse.SessionRegistry.lookup(ctx.name, id)
    session_monitor = Process.monitor(session)
    send(joined.channel_pid, {FinancialDataAccess, :configuration_changed, "rotated"})
    monitor = Process.monitor(joined.channel_pid)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 2_000
    assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}, 2_000
    {:ok, records, _} = TranscriptStore.read(ctx.root, id)
    assert Enum.any?(records, &(&1["type"] == "session_ended" and &1["reason"] == "auth_changed"))
  end

  test "drafts are relayed and only client confirmation delivers edited text", ctx do
    start_core(ctx)
    assert {:ok, %{conversation_id: id}, joined} = subscribe_and_join(client(), "voice:converse", payload())
    FakeProvider.emit(provider(ctx.name, id), %Events.ToolCall{call_id: "proposal", name: "propose_instruction", params: %{"text" => "original"}})
    assert_push("draft", %{"draft_id" => draft, "status" => "proposed", "text" => "original"}, 2_000)
    assert {:ok, records, _} = TranscriptStore.read(ctx.root, id)
    refute Enum.any?(records, &(&1["status"] == "confirmed"))
    push(joined, "confirm_draft", %{"draft_id" => draft, "edited_text" => "edited"})
    assert_push("delivery", %{"draft_id" => ^draft, "status" => "confirmed"}, 2_000)
    assert {:ok, records, _} = TranscriptStore.read(ctx.root, id)
    assert Enum.any?(records, &(&1["draft_id"] == draft and &1["text"] == "edited" and &1["edited"] == true))
    FakeProvider.emit(provider(ctx.name, id), %Events.ToolCall{call_id: "discard", name: "propose_instruction", params: %{"text" => "unused"}})
    assert_push("draft", %{"draft_id" => discarded, "text" => "unused"}, 2_000)
    push(joined, "discard_draft", %{"draft_id" => discarded})
    assert_push("delivery", %{"draft_id" => ^discarded, "status" => "discarded"}, 2_000)
  end

  test "a grace-period session keeps its capacity lease and reconnect reuses it", ctx do
    start_core(ctx)
    assert {:ok, %{conversation_id: id}, first} = subscribe_and_join(client(), "voice:converse", payload())
    request2 = Map.put(payload(), "client_session_id", "two")
    assert {:ok, _, _} = subscribe_and_join(client(), "voice:converse", request2)
    ref = leave(first)
    assert_reply(ref, :ok)
    assert {:error, %{reason_code: "capacity"}} = subscribe_and_join(client(), "voice:converse", Map.put(payload(), "client_session_id", "three"))
    assert {:ok, %{conversation_id: ^id}, _} = subscribe_and_join(client(), "voice:converse", payload())
  end

  test "mid-session provider errors carry a cause and end state", ctx do
    start_core(ctx)
    assert {:ok, %{conversation_id: id}, _} = subscribe_and_join(client(), "voice:converse", payload())
    FakeProvider.emit(provider(ctx.name, id), Events.Error.new(:provider_quota, "Quota exhausted."))
    assert_push("error", %{"reason_code" => "provider_quota", "message" => "Quota exhausted."}, 2_000)
    assert_push("state", %{"state" => "ended"}, 2_000)
  end

  defp start_core(ctx, fake \\ []) do
    {:ok, config} =
      Config.new(
        name: ctx.name,
        transcript_root: ctx.root,
        credentials: StaticCredentials,
        agent_channel: AgentChannel,
        allowed_tools: ["get_status", "end_conversation"],
        briefing_source: Briefing,
        provider: {FakeProvider, Keyword.put_new(fake, :script, [%Events.ProviderConversationId{id: "fake-session"}])},
        limits: %{max_sessions: 4},
        llm: "test-model",
        cloud_disclosure_accepted: true
      )

    start_supervised!(VoiceConverse.child_spec(config))
  end

  defp provider(instance, id) do
    {:ok, session} = VoiceConverse.SessionRegistry.lookup(instance, id)
    :sys.get_state(session).provider_ref
  end

  defp client(connection \\ "same") do
    {:ok, generation} = FinancialDataAccess.current_configuration_generation()
    socket(VoiceSocket, "converse-test", %{voice_authority: %{configuration_generation: generation, connection_generation: connection}})
  end

  defp payload, do: %{"v" => 1, "mode" => "converse", "surface" => "conversation_panel", "target" => %{"kind" => "executor", "instance_id" => "test"}, "client_session_id" => "client-one"}
  defp report, do: %{instance: %{instance_id: "test"}, capabilities: %{"voice.conversation" => %{state: :available}, "executor.conversation" => %{state: :available}}}
  defp restore(key, {:ok, value}), do: Application.put_env(:aiur, key, value)
  defp restore(key, :error), do: Application.delete_env(:aiur, key)
end
