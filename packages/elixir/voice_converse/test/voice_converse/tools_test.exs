defmodule VoiceConverse.ToolsTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.{Briefing, Config, Drafts, Events, SessionRegistry, TranscriptStore}
  alias VoiceConverse.Testing.{FakeCommandSource, FakeProvider, StaticCredentials}

  setup do
    root = Path.join(System.tmp_dir!(), "voice_converse_tools_#{System.unique_integer([:positive])}")
    name = Module.concat([VoiceConverse, "ToolsTest#{System.unique_integer([:positive])}"])
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    StaticCredentials.put(%{fake: "test-secret"})
    on_exit(fn -> VoiceConverse.TestCleanup.rm_rf!(root) end)
    %{root: root, name: name}
  end

  test "absent CommandSource says unavailable rather than no open Commands", %{root: root, name: name} do
    id = start!(root, name, %{id: "target"})
    provider = provider(name, id)

    :ok = FakeProvider.emit(provider, tool_call("list_open_commands"))

    assert_receive {:fake_provider, :tool_result, "call-1", %{text: text, is_error: false}}
    assert text =~ "unavailable"
    refute text =~ "No open Commands"
  end

  test "get_details clamps n and redacts its summary", %{root: root, name: name} do
    target = %{
      id: "target",
      sections: [%{id: "conversation", description: "Recent conversation"}],
      details: %{"conversation" => "Bearer abcdefgh12345"},
      observer: self()
    }

    id = start!(root, name, target)
    provider = provider(name, id)

    :ok = FakeProvider.emit(provider, tool_call("get_details", %{"section" => "conversation", "n" => 500}))

    assert_receive {:details_options, [n: 30]}
    assert_receive {:fake_provider, :tool_result, "call-1", %{text: text, is_error: false}}
    assert text =~ "[redacted]"
    refute text =~ "abcdefgh"
  end

  test "tool call and result are durable before FakeProvider sees its result", %{root: root, name: name} do
    id = start!(root, name, %{id: "target"}, fake: [tool_result_observer: self()])

    :ok = FakeProvider.emit(provider(name, id), tool_call("get_status"))

    assert_receive {:fake_provider, :tool_result_before_return, session, "call-1", _result}
    assert {:ok, records, _meta} = TranscriptStore.read(root, id)

    assert [%{"type" => "tool_call"}, %{"type" => "tool_result"}] =
             Enum.take(Enum.filter(records, &(&1["type"] =~ "tool_")), 2)

    send(session, {:continue_tool_result, "call-1"})
  end

  test "unknown tool returns an error result", %{root: root, name: name} do
    id = start!(root, name, %{id: "target"})
    provider = provider(name, id)

    :ok = FakeProvider.emit(provider, tool_call("not_a_tool"))

    assert_receive {:fake_provider, :tool_result, "call-1", %{text: "Unknown tool.", is_error: true}}
  end

  test "propose_instruction creates a proposed draft and sends nothing", %{root: root, name: name} do
    id = start!(root, name, %{id: "target"})
    provider = provider(name, id)

    :ok = FakeProvider.emit(provider, tool_call("propose_instruction", %{"text" => "ship this"}))

    assert_receive {:voice_conversation, ^id,
                    {:draft,
                     %{
                       draft_id: draft_id,
                       kind: "instruction",
                       status: "proposed",
                       text: "ship this",
                       target: %{id: "target"}
                     }}}

    assert draft_id =~ ~r/\Avd_[A-Za-z0-9_-]{22}\z/

    assert_receive {:fake_provider, :tool_result, "call-1", %{text: text, is_error: false}}
    assert text == "Draft #{draft_id} is waiting for the operator to confirm. Do not say it was sent."
    refute Enum.any?(FakeProvider.calls(provider), &match?({:send_user_text, _}, &1))

    assert {:ok, records, _meta} = TranscriptStore.read(root, id)
    assert Enum.any?(records, &(&1["type"] == "draft" and &1["draft_id"] == draft_id and &1["status"] == "proposed"))
  end

  test "provider confirmation-like tools leave drafts proposed", %{root: root, name: name} do
    id = start!(root, name, %{id: "target"})
    provider = provider(name, id)
    :ok = FakeProvider.emit(provider, tool_call("propose_instruction", %{"text" => "ship this"}))

    assert_receive {:voice_conversation, ^id, {:draft, %{draft_id: draft_id, status: "proposed"}}}
    assert_receive {:fake_provider, :tool_result, "call-1", %{is_error: false}}

    for tool_name <- ["confirm_draft", "confirm", "send"] do
      :ok = FakeProvider.emit(provider, %Events.ToolCall{call_id: tool_name, name: tool_name, params: %{}})
      assert_receive {:fake_provider, :tool_result, ^tool_name, %{is_error: true}}
      assert_draft_status(name, id, draft_id, :proposed)
    end

    refute Enum.any?(FakeProvider.calls(provider), &match?({:send_user_text, _}, &1))
  end

  test "provider transcript confirmation words leave drafts proposed", %{root: root, name: name} do
    id = start!(root, name, %{id: "target"})
    provider = provider(name, id)
    :ok = FakeProvider.emit(provider, tool_call("propose_instruction", %{"text" => "ship this"}))

    assert_receive {:voice_conversation, ^id, {:draft, %{draft_id: draft_id, status: "proposed"}}}
    assert_receive {:fake_provider, :tool_result, "call-1", %{is_error: false}}

    :ok = FakeProvider.emit(provider, %Events.UserTranscript{text: "yes, confirm and send it", final?: true})

    :ok =
      FakeProvider.emit(provider, %Events.AgentText{turn_id: "assistant", text: "Confirmed, sending now", final?: true})

    assert_receive {:voice_conversation, ^id, %Events.UserTranscript{final?: true}}
    assert_receive {:voice_conversation, ^id, %Events.AgentText{final?: true}}
    assert_draft_status(name, id, draft_id, :proposed)
    refute Enum.any?(FakeProvider.calls(provider), &match?({:send_user_text, _}, &1))
  end

  test "tool specifications use host detail sections and optional CommandSource", %{root: root, name: name} do
    target = %{id: "target", sections: [%{id: "notes", description: "Host notes"}]}
    _id = start!(root, name, target, command_source: FakeCommandSource, fake: [open_observer: self()])

    assert_receive {:fake_provider, :open_spec, %{tools: tools}}

    assert Enum.map(tools, & &1.name) == [
             "get_status",
             "get_details",
             "list_open_commands",
             "propose_instruction",
             "end_conversation"
           ]

    assert Enum.at(tools, 1).parameters["properties"]["section"]["enum"] == ["notes"]
  end

  test "end_conversation records its reply before ending the session", %{root: root, name: name} do
    id = start!(root, name, %{id: "target"})
    provider = provider(name, id)

    :ok = FakeProvider.emit(provider, tool_call("end_conversation"))

    assert_receive {:fake_provider, :tool_result, "call-1", %{text: "Ending.", is_error: false}}
    assert_receive {:voice_conversation, ^id, {:ended, :user_end}}, 1_000
    assert {:ok, records, _meta} = TranscriptStore.read(root, id)
    assert Enum.any?(records, &(&1["type"] == "tool_result" and &1["summary"] == "Ending."))
  end

  defp start!(root, name, target, opts \\ []) do
    {:ok, config} =
      Config.new(
        name: name,
        transcript_root: root,
        credentials: StaticCredentials,
        briefing_source: ToolBriefingSource,
        command_source: Keyword.get(opts, :command_source),
        provider: {FakeProvider, []},
        llm: "test-model",
        cloud_disclosure_accepted: true
      )

    start_supervised!(VoiceConverse.child_spec(config))

    fake =
      opts
      |> Keyword.get(:fake, [])
      |> Keyword.put(:script, [%Events.ProviderConversationId{id: "provider-session"}])
      |> Keyword.put_new(:call_observer, self())

    {:ok, id} = VoiceConverse.start_session(name, target, client: self(), provider: {FakeProvider, fake})
    assert_receive {:voice_conversation_state, ^id, :connecting}
    assert_receive {:voice_conversation_state, ^id, :listening}
    id
  end

  defp provider(name, id) do
    {:ok, session} = SessionRegistry.lookup(name, id)
    :sys.get_state(session).provider_ref
  end

  defp assert_draft_status(name, id, draft_id, status) do
    {:ok, session} = SessionRegistry.lookup(name, id)
    assert {:ok, %{status: ^status}} = :sys.get_state(session).drafts |> Drafts.fetch(draft_id)
  end

  defp tool_call(name, params \\ %{}), do: %Events.ToolCall{call_id: "call-1", name: name, params: params}
end

defmodule ToolBriefingSource do
  @behaviour VoiceConverse.Ports.BriefingSource

  alias VoiceConverse.Briefing

  @impl true
  def describe_target(target), do: %{id: target.id, kind: :test, title: "Test target"}

  @impl true
  def brief(target) do
    if target[:exit], do: exit(:boom)
    {:ok, Map.get(target, :briefing, %Briefing{})}
  end

  @impl true
  def details(target, section, opts) do
    if observer = target[:observer], do: send(observer, {:details_options, opts})
    {:ok, get_in(target, [:details, section]) || ""}
  end

  @impl true
  def sections(target), do: Map.get(target, :sections, [])

  @impl true
  def subscribe(_target, _pid), do: :unsupported

  @impl true
  def alive?(_target), do: :unknown
end
