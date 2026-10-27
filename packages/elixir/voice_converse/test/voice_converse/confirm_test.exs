defmodule VoiceConverse.ConfirmTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.{Config, Events, SessionRegistry, TranscriptStore}
  alias VoiceConverse.Testing.{FakeAgentChannel, FakeProvider, StaticCredentials}

  setup do
    root = Path.join(System.tmp_dir!(), "voice_converse_confirm_#{System.unique_integer([:positive])}")
    name = Module.concat([VoiceConverse, "ConfirmTest#{System.unique_integer([:positive])}"])
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    StaticCredentials.put(%{fake: "test-secret"})
    on_exit(fn -> VoiceConverse.TestCleanup.rm_rf!(root) end)
    %{root: root, name: name}
  end

  test "an unconfirmed draft never instructs the agent", %{root: root, name: name} do
    id = start!(root, name)
    _draft_id = propose(name, id)

    refute_receive {:fake_channel, {:instruct, _, _}}
  end

  test "client confirmation instructs exactly once with the draft id", %{root: root, name: name} do
    id = start!(root, name)
    draft_id = propose(name, id)

    assert {:ok, %{draft_id: ^draft_id, status: :confirmed}} =
             VoiceConverse.confirm_draft(name, id, draft_id, origin: :client)

    assert_receive {:fake_channel, {:instruct, "ship it", ^draft_id}}

    assert {:ok, %{status: :confirmed}} = VoiceConverse.confirm_draft(name, id, draft_id, origin: :client)
    refute_receive {:fake_channel, {:instruct, _, _}}
  end

  test "a non-client origin cannot confirm or instruct", %{root: root, name: name} do
    id = start!(root, name)
    draft_id = propose(name, id)

    assert {:error, :not_client} = VoiceConverse.confirm_draft(name, id, draft_id, origin: :provider)
    refute_receive {:fake_channel, {:instruct, _, _}}
  end

  test "a draft becomes stale when its target ends before confirmation", %{root: root, name: name} do
    alive = start_supervised!({Agent, fn -> :unknown end})
    id = start!(root, name, target: %{id: "target", test_pid: self(), alive: fn -> Agent.get(alive, & &1) end})
    draft_id = propose(name, id)
    Agent.update(alive, fn _ -> false end)

    assert {:error, :target_stale} = VoiceConverse.confirm_draft(name, id, draft_id, origin: :client)
    refute_receive {:fake_channel, {:instruct, _, _}}
    assert {:ok, session} = SessionRegistry.lookup(name, id)

    assert {:ok, %{status: :stale}} =
             session |> :sys.get_state() |> Map.fetch!(:drafts) |> VoiceConverse.Drafts.fetch(draft_id)
  end

  test "editing records and sends the edited text", %{root: root, name: name} do
    id = start!(root, name)
    draft_id = propose(name, id)

    assert {:ok, %{text: "test the confirmation", edited?: true}} =
             VoiceConverse.confirm_draft(name, id, draft_id, origin: :client, edited_text: "test the confirmation")

    assert_receive {:fake_channel, {:instruct, "test the confirmation", ^draft_id}}
    assert {:ok, records, _meta} = TranscriptStore.read(root, id)

    assert Enum.any?(records, fn record ->
             record["type"] == "draft" and record["draft_id"] == draft_id and
               record["text"] == "test the confirmation" and record["edited"] == true
           end)
  end

  test "discarding a draft persists the terminal state without instructing", %{root: root, name: name} do
    id = start!(root, name)
    draft_id = propose(name, id)

    assert {:ok, %{status: :discarded}} = VoiceConverse.discard_draft(name, id, draft_id, origin: :client)
    refute_receive {:fake_channel, {:instruct, _, _}}
  end

  test "a delivery error is durable and a later client confirm retries", %{root: root, name: name} do
    failure = start_supervised!({Agent, fn -> true end})

    id =
      start!(root, name,
        target: %{id: "target", test_pid: self(), failure: failure},
        agent_channel: FailingAgentChannel
      )

    draft_id = propose(name, id)

    assert {:error, :temporary} = VoiceConverse.confirm_draft(name, id, draft_id, origin: :client)
    assert_receive {:failing_channel, {:instruct, "ship it", ^draft_id}}

    assert {:ok, %{status: :confirmed}} = VoiceConverse.confirm_draft(name, id, draft_id, origin: :client)
    assert_receive {:failing_channel, {:instruct, "ship it", ^draft_id}}
    assert {:ok, records, _meta} = TranscriptStore.read(root, id)
    assert Enum.any?(records, &(&1["type"] == "draft" and &1["draft_id"] == draft_id and &1["status"] == "failed"))
  end

  defp start!(root, name, opts \\ []) do
    {:ok, config} =
      Config.new(
        name: name,
        transcript_root: root,
        credentials: StaticCredentials,
        briefing_source: ConfirmBriefingSource,
        agent_channel: Keyword.get(opts, :agent_channel, FakeAgentChannel),
        provider: {FakeProvider, []},
        llm: "test-model",
        cloud_disclosure_accepted: true
      )

    start_supervised!(VoiceConverse.child_spec(config))

    {:ok, id} =
      VoiceConverse.start_session(name, Keyword.get(opts, :target, %{id: "target", test_pid: self()}),
        client: self(),
        provider: {FakeProvider, [script: [%Events.ProviderConversationId{id: "provider-session"}]]}
      )

    assert_receive {:voice_conversation_state, ^id, :connecting}
    assert_receive {:voice_conversation_state, ^id, :listening}
    id
  end

  defp propose(name, id) do
    {:ok, session} = SessionRegistry.lookup(name, id)

    :ok =
      FakeProvider.emit(
        :sys.get_state(session).provider_ref,
        %Events.ToolCall{call_id: "propose", name: "propose_instruction", params: %{"text" => "ship it"}}
      )

    assert_receive {:voice_conversation, ^id, {:draft, %{draft_id: draft_id, status: "proposed"}}}
    draft_id
  end
end

defmodule FailingAgentChannel do
  @behaviour VoiceConverse.Ports.AgentChannel

  def instruct(target, text, key, _opts) do
    send(target.test_pid, {:failing_channel, {:instruct, text, key}})

    if target[:failure] && Agent.get_and_update(target.failure, fn failed? -> {failed?, false} end) do
      {:error, :temporary}
    else
      {:ok, make_ref()}
    end
  end

  defdelegate ask(target, question, ref, opts), to: VoiceConverse.Testing.FakeAgentChannel
  defdelegate fork_query(target, question, opts), to: VoiceConverse.Testing.FakeAgentChannel
  defdelegate subscribe(target, pid), to: VoiceConverse.Testing.FakeAgentChannel
  defdelegate capabilities(target), to: VoiceConverse.Testing.FakeAgentChannel
end

defmodule ConfirmBriefingSource do
  @behaviour VoiceConverse.Ports.BriefingSource

  defdelegate describe_target(target), to: VoiceConverse.Testing.FakeBriefingSource
  defdelegate brief(target), to: VoiceConverse.Testing.FakeBriefingSource
  defdelegate details(target, section, opts), to: VoiceConverse.Testing.FakeBriefingSource
  defdelegate sections(target), to: VoiceConverse.Testing.FakeBriefingSource
  defdelegate subscribe(target, pid), to: VoiceConverse.Testing.FakeBriefingSource

  def alive?(%{alive: alive}) when is_function(alive, 0), do: alive.()
  def alive?(target), do: VoiceConverse.Testing.FakeBriefingSource.alive?(target)
end
