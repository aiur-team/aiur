defmodule VoiceConverse.ToolsTest do
  use ExUnit.Case, async: false

  defmacrop receive_barrier(pattern) do
    quote do
      receive do
        unquote(pattern) = message -> message
      after
        5_000 -> flunk("timed out waiting for a voice-converse message")
      end
    end
  end

  alias VoiceConverse.{Briefing, Config, Drafts, Events, SessionRegistry, Tools, TranscriptStore}
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

  test "host tools are exposed, called, redacted and recorded", %{root: root, name: name} do
    target = %{id: "target", observer: self()}

    id =
      start!(root, name, target,
        host_tools: FakeHostTools,
        redactor: fn _ -> "[redacted]" end,
        fake: [open_observer: self()]
      )

    provider = provider(name, id)

    assert {:fake_provider, :open_spec, %{tools: tools}} =
             receive_barrier({:fake_provider, :open_spec, %{tools: _tools}})

    assert Enum.find(tools, &(&1.name == "budget_estimate")) == %{
             name: "budget_estimate",
             description: "Estimate a budget.",
             parameters: %{
               "type" => "object",
               "properties" => %{"amount" => %{"type" => "number"}},
               "required" => ["amount"]
             }
           }

    :ok =
      FakeProvider.emit(
        provider,
        tool_call("budget_estimate", %{"amount" => 50, "token" => "Bearer host-param-secret"})
      )

    assert {:host_tool_call, "budget_estimate", %{"amount" => 50, "token" => "Bearer host-param-secret"}} =
             receive_barrier({:host_tool_call, "budget_estimate", _params})

    assert {:fake_provider, :tool_result, "call-1", %{text: "[redacted]", is_error: false}} =
             receive_barrier({:fake_provider, :tool_result, "call-1", _result})

    :ok = FakeProvider.emit(provider, %Events.ToolCall{call_id: "built-in", name: "get_status", params: %{}})

    assert {:fake_provider, :tool_result, "built-in", %{is_error: false}} =
             receive_barrier({:fake_provider, :tool_result, "built-in", _result})

    assert {:ok, records, _meta} = TranscriptStore.read(root, id)

    assert Enum.any?(records, fn record ->
             record["type"] == "tool_result" and record["call_id"] == "call-1" and
               record["name"] == "budget_estimate" and record["is_error"] == false and
               record["summary"] == "[redacted]"
           end)

    assert Enum.any?(records, fn record ->
             record["type"] == "tool_call" and record["call_id"] == "call-1" and
               record["name"] == "budget_estimate" and record["params"]["token"] == "[redacted]"
           end)

    refute inspect(records) =~ "host-param-secret"
  end

  test "host tool collision is rejected before provider start", %{root: root, name: name} do
    {:ok, config} = config(root, name, host_tools: FakeHostTools)
    start_supervised!(VoiceConverse.child_spec(config))
    assert {:error, :host_tool_name_conflict} = VoiceConverse.start_session(name, %{id: "collision"}, client: self())
  end

  test "invalid host tool specs are rejected separately from name conflicts", %{root: root, name: name} do
    {:ok, config} = config(root, name, host_tools: FakeHostTools)
    start_supervised!(VoiceConverse.child_spec(config))
    assert {:error, :invalid_host_tools} = VoiceConverse.start_session(name, %{id: "invalid"}, client: self())
  end

  test "host tool timeout returns an error result", %{root: root, name: name} do
    id = start!(root, name, %{id: "slow"}, host_tools: FakeHostTools)
    provider = provider(name, id)

    :ok = FakeProvider.emit(provider, tool_call("budget_estimate"))

    assert {:fake_provider, :tool_result, "call-1", %{text: "Host tool unavailable.", is_error: true}} =
             receive_barrier({:fake_provider, :tool_result, "call-1", _result})
  end

  test "host tool exit returns an error result", %{root: root, name: name} do
    id = start!(root, name, %{id: "exit"}, host_tools: FakeHostTools)
    provider = provider(name, id)

    :ok = FakeProvider.emit(provider, tool_call("budget_estimate"))

    assert {:fake_provider, :tool_result, "call-1", %{text: "Host tool unavailable.", is_error: true}} =
             receive_barrier({:fake_provider, :tool_result, "call-1", _result})
  end

  test "session reuses the host tool catalog resolved at startup", %{root: root, name: name} do
    counter = start_supervised!({Agent, fn -> 0 end})
    target = %{id: "changing", observer: self(), specs_counter: counter}

    id =
      start!(root, name, target,
        host_tools: FakeHostTools,
        redactor: fn text -> text end,
        fake: [open_observer: self()]
      )

    provider = provider(name, id)

    assert {:fake_provider, :open_spec, %{tools: tools}} =
             receive_barrier({:fake_provider, :open_spec, %{tools: _tools}})

    assert Enum.any?(tools, &(&1.name == "budget_estimate"))
    assert :host_tool_specs_loaded = receive_barrier(:host_tool_specs_loaded)
    assert Agent.get(counter, & &1) == 1

    :ok = FakeProvider.emit(provider, tool_call("budget_estimate"))

    assert {:fake_provider, :tool_result, "call-1", %{text: "Bearer host-secret", is_error: false}} =
             receive_barrier({:fake_provider, :tool_result, "call-1", _result})

    assert Agent.get(counter, & &1) == 1
  end

  test "allowed_tools excludes host tools from specs and dispatch", %{root: root, name: name} do
    target = %{id: "target", observer: self()}
    {:ok, unrestricted} = config(root, name, host_tools: FakeHostTools)
    assert Enum.any?(Tools.specs(unrestricted, target), &(&1.name == "budget_estimate"))

    id =
      start!(root, name, target,
        host_tools: FakeHostTools,
        allowed_tools: ["get_status"],
        fake: [open_observer: self()]
      )

    provider = provider(name, id)

    assert {:fake_provider, :open_spec, %{tools: tools}} =
             receive_barrier({:fake_provider, :open_spec, %{tools: _tools}})

    refute Enum.any?(tools, &(&1.name == "budget_estimate"))

    :ok = FakeProvider.emit(provider, tool_call("budget_estimate"))

    assert {:fake_provider, :tool_result, "call-1", %{is_error: true}} =
             receive_barrier({:fake_provider, :tool_result, "call-1", _result})

    refute_received {:host_tool_call, "budget_estimate", _params}
  end

  test "host allowlist refuses instruction tools before creating a draft", %{root: root, name: name} do
    id = start!(root, name, %{id: "target"}, allowed_tools: ["get_status", "end_conversation"])
    provider = provider(name, id)
    :ok = FakeProvider.emit(provider, tool_call("propose_instruction", %{"text" => "Send this now"}))

    assert_receive {:fake_provider, :tool_result, "call-1",
                    %{is_error: true, text: "Tool is unavailable in this conversation."}}

    {:ok, session} = SessionRegistry.lookup(name, id)
    assert :sys.get_state(session).drafts == Drafts.new()
    assert {:ok, records, _meta} = TranscriptStore.read(root, id)
    refute Enum.any?(records, &(&1["type"] == "draft"))
  end

  test "propose_instruction creates a proposed draft and sends nothing", %{root: root, name: name} do
    id = start!(root, name, %{id: "target"}, redactor: fn _ -> "[redacted]" end)
    provider = provider(name, id)

    :ok = FakeProvider.emit(provider, tool_call("propose_instruction", %{"text" => "Bearer secret"}))

    assert_receive {:voice_conversation, ^id,
                    %Events.ToolCall{name: "propose_instruction", params: %{"text" => "[redacted]"}}}

    assert_receive {:voice_conversation, ^id,
                    {:draft,
                     %{
                       draft_id: draft_id,
                       kind: "instruction",
                       status: "proposed",
                       text: "[redacted]",
                       target: %{id: "target"}
                     }}}

    assert draft_id =~ ~r/\Avd_[A-Za-z0-9_-]{22}\z/

    assert_receive {:fake_provider, :tool_result, "call-1", %{text: text, is_error: false}}
    assert text == "Draft #{draft_id} is waiting for the operator to confirm. Do not say it was sent."
    refute Enum.any?(FakeProvider.calls(provider), &match?({:send_user_text, _}, &1))

    assert {:ok, records, _meta} = TranscriptStore.read(root, id)
    refute inspect(records) =~ "secret"
    assert Enum.any?(records, &(&1["type"] == "tool_call" and &1["params"]["text"] == "[redacted]"))
    assert Enum.any?(records, &(&1["type"] == "draft" and &1["draft_id"] == draft_id and &1["status"] == "proposed"))
  end

  test "a draft is durable before subscribers receive it", %{root: root, name: name} do
    test_pid = self()

    event_broadcast = fn subscribers, id, event ->
      if match?({:draft, _}, event) do
        send(test_pid, {:draft_ready_to_broadcast, id})

        receive do
          :release_draft_broadcast -> :ok
        end
      end

      Enum.each(Map.keys(subscribers), &send(&1, {:voice_conversation, id, event}))
    end

    id = start!(root, name, %{id: "target"}, event_broadcast: event_broadcast)
    provider = provider(name, id)

    :ok = FakeProvider.emit(provider, tool_call("propose_instruction", %{"text" => "ship this"}))

    assert_receive {:draft_ready_to_broadcast, ^id}
    assert {:ok, records, _meta} = TranscriptStore.read(root, id)
    assert Enum.any?(records, &(&1["type"] == "draft" and &1["status"] == "proposed"))

    {:ok, session} = SessionRegistry.lookup(name, id)
    send(session, :release_draft_broadcast)
    assert_receive {:voice_conversation, ^id, {:draft, %{status: "proposed"}}}
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
    {:ok, config} = config(root, name, opts)

    start_supervised!(VoiceConverse.child_spec(config))

    fake =
      opts
      |> Keyword.get(:fake, [])
      |> Keyword.put(:script, [%Events.ProviderConversationId{id: "provider-session"}])
      |> Keyword.put_new(:call_observer, self())

    {:ok, id} =
      VoiceConverse.start_session(
        name,
        target,
        Keyword.merge([client: self(), provider: {FakeProvider, fake}], Keyword.drop(opts, [:fake, :redactor]))
      )

    assert_receive {:voice_conversation_state, ^id, :connecting}
    assert_receive {:voice_conversation_state, ^id, :listening}
    id
  end

  defp config(root, name, opts) do
    Config.new(
      name: name,
      transcript_root: root,
      credentials: StaticCredentials,
      briefing_source: ToolBriefingSource,
      command_source: Keyword.get(opts, :command_source),
      host_tools: Keyword.get(opts, :host_tools),
      provider: {FakeProvider, []},
      allowed_tools: Keyword.get(opts, :allowed_tools),
      llm: "test-model",
      cloud_disclosure_accepted: true,
      redactor: Keyword.get(opts, :redactor, &VoiceConverse.Redact.redact/1)
    )
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

defmodule FakeHostTools do
  @behaviour VoiceConverse.Ports.HostTools

  @impl true
  def specs(%{id: "collision"}) do
    {:ok, [%{name: "get_status", description: "Collision", params: %{"type" => "object"}}]}
  end

  def specs(%{id: "invalid"}) do
    {:ok, [%{name: "budget_estimate", description: "Missing params"}]}
  end

  def specs(%{id: "changing", specs_counter: counter} = target) do
    case Agent.get_and_update(counter, fn count -> {count, count + 1} end) do
      0 ->
        if observer = target[:observer], do: send(observer, :host_tool_specs_loaded)
        {:ok, [budget_spec()]}

      _later_call ->
        {:error, :unavailable}
    end
  end

  def specs(_target) do
    {:ok, [budget_spec()]}
  end

  @impl true
  def call("budget_estimate", %{id: "slow"}, _params) do
    Process.sleep(500)
    {:ok, "too late"}
  end

  def call("budget_estimate", %{id: "exit"}, _params), do: exit(:boom)

  def call(name, target, params) do
    if observer = target[:observer], do: send(observer, {:host_tool_call, name, params})
    {:ok, "Bearer host-secret"}
  end

  defp budget_spec do
    %{
      name: "budget_estimate",
      description: "Estimate a budget.",
      params: %{
        "type" => "object",
        "properties" => %{"amount" => %{"type" => "number"}},
        "required" => ["amount"]
      }
    }
  end
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
