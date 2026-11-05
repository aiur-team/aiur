defmodule AgentConversation.ClientTest do
  use ExUnit.Case, async: true

  alias AgentConversation.{Client, FixtureTransport, HostFixture}

  defp entries(range), do: Enum.map(range, &%{pos: &1, kind: "message", role: "agent", body: "entry #{&1}"})

  defp seeded(conversation_id, count \\ 3, opts \\ []) do
    {:ok, host} = HostFixture.host(conversation_id, opts)
    FixtureTransport.put_conversation(conversation_id, entries(1..count), opts)
    {host, conversation_id}
  end

  test "mounting a conversation the scope does not register is refused without a transport call" do
    {host, _id} = seeded("conv-mount-denied")

    assert {:error, :out_of_scope} = Client.mount(host, "conv-somebody-else")
  end

  test "mounting loads the tail, anchors, Commands and voice report" do
    commands = [%{id: "cmd-1", question: "Ship it?", pos: 2}]

    {host, id} =
      seeded("conv-mount", 3,
        commands: commands,
        anchors: [%{pos: 2, kind: "pr_merged", label: "PR merged"}],
        voice: {:ok, %{dictation: true}},
        features: %{send: true, voice: :dictation, commands: true}
      )

    assert {:ok, client} = Client.mount(host, id)
    assert Client.state(client) == :ready
    assert Enum.map(Client.entries(client), & &1.pos) == [1, 2, 3]
    assert client.anchors == [%{pos: 2, kind: "pr_merged", label: "PR merged"}]
    assert [%{id: "cmd-1"}] = client.commands
    assert client.command_slots == %{"cmd-1" => {:at_pos, 2}}
    assert AgentConversation.Voice.status(client.voice) == :available
  end

  test "pagination and the live tail reconcile into one ordered transcript" do
    {host, id} = seeded("conv-paging", 120)
    {:ok, client} = Client.mount(host, id)

    assert Enum.map(Client.entries(client), & &1.pos) == Enum.to_list(71..120)

    {:ok, client, effects} = Client.load_older(client)
    assert effects == []
    assert Enum.map(Client.entries(client), & &1.pos) == Enum.to_list(21..120)

    live = Client.receive_live(client, [%{pos: 121, kind: "message", role: "agent", body: "live"}])
    assert live.timeline |> AgentConversation.Timeline.visible() |> List.last() |> Map.get(:pos) == 121
    refute Enum.any?(Client.entries(live), &(&1.body == "live" and &1.pos <= 120))
  end

  test "a reconnect discards replayed entries the catch-up page already covers" do
    {host, id} = seeded("conv-reconnect", 3)
    {:ok, client} = Client.mount(host, id)

    client = Client.disconnect(client)

    client =
      Client.receive_live(client, [
        %{pos: 3, kind: "message", role: "agent", body: "replay"},
        %{pos: 4, kind: "message", role: "agent", body: "new"}
      ])

    assert client.buffered != []

    FixtureTransport.append(id, [%{pos: 4, kind: "message", role: "agent", body: "new"}])
    {:ok, client, []} = Client.reconnect(client)

    positions = Enum.map(Client.entries(client), & &1.pos)
    assert positions == [1, 2, 3, 4]
    assert Enum.find(Client.entries(client), &(&1.pos == 3)).body == "entry 3"
    assert client.buffered == []
  end

  test "a conversation outside the scope denies reads, sends and Command answers" do
    commands = [%{id: "cmd-scope", question: "Ship it?", pos: 1}]

    {host, id} =
      seeded("conv-scope", 2,
        commands: commands,
        actions: [:read, :send, :answer_command],
        features: %{send: true, commands: true}
      )

    {:ok, client} = Client.mount(host, id)

    {:ok, empty_scope} = AgentConversation.Scope.new(games: ["other-game"])
    narrowed = %{client | host: %{host | scope: empty_scope}}

    assert {:error, :out_of_scope} = Client.jump_latest(narrowed)
    assert {:error, :out_of_scope} = Client.reveal(narrowed, 1)
    assert {:error, :out_of_scope} = Client.send_text(narrowed, "hello")
    assert {:error, :out_of_scope} = Client.answer(narrowed, "cmd-scope", %{option: "yes"})
    assert FixtureTransport.sent(id) == []
  end

  test "sending text requires the send grant and clears the draft only on delivery" do
    {read_only, id} = seeded("conv-read-only", 2, actions: [:read], features: %{send: true})
    {:ok, client} = Client.mount(read_only, id)
    client = Client.draft(client, "hello")

    assert {:error, :permission_denied} = Client.send_text(client, client.draft)
    assert FixtureTransport.sent(id) == []
    assert client.draft == "hello"

    {writable, id} = seeded("conv-send", 2)
    {:ok, client} = Client.mount(writable, id)
    {:ok, client, effects} = Client.send_text(client, "hello")

    assert FixtureTransport.sent(id) == ["hello"]
    assert client.draft == ""
    assert effects == [:clear_draft, {:push, "conversation-bottom", %{}}]
    assert {:error, :empty_message} = Client.send_text(client, "   ")
  end

  test "the mounted send feature gates delivery even when the scope grants it" do
    {host, id} = seeded("conv-no-send-feature", 2, features: %{send: false})
    {:ok, client} = Client.mount(host, id)

    assert {:error, :permission_denied} = Client.send_text(client, "hello")
    assert FixtureTransport.sent(id) == []
  end

  test "a Command answered elsewhere records the conflict and keeps the row" do
    commands = [%{id: "cmd-conflict", question: "Restart?", pos: 1}]

    {host, id} =
      seeded("conv-conflict", 2, commands: commands, actions: [:read, :answer_command], features: %{commands: true})

    {:ok, client} = Client.mount(host, id)

    {:ok, client, []} = Client.answer(client, "cmd-conflict", %{option: "yes"})
    assert client.command_outcomes["cmd-conflict"].outcome == :answered
    assert AgentConversation.Commands.notice(client.command_outcomes, "cmd-conflict") == nil

    {:ok, client, []} = Client.answer(client, "cmd-conflict", %{option: "no"})
    assert client.command_outcomes["cmd-conflict"].outcome == :already_answered
    assert AgentConversation.Commands.notice(client.command_outcomes, "cmd-conflict") =~ "Another answer landed first"
    assert Enum.map(client.commands, & &1.id) == ["cmd-conflict"]
  end

  test "answering a Command needs the read grant of this conversation and the commands feature" do
    {no_commands, id} = seeded("conv-no-commands", 1, actions: [:read, :answer_command], features: %{commands: false})
    {:ok, client} = Client.mount(no_commands, id)

    assert {:error, :permission_denied} = Client.answer(client, "cmd-1", %{option: "yes"})
  end

  test "voice is unavailable, ready or denied according to the host report" do
    {host, id} = seeded("conv-voice-none", 1, features: %{voice: false})
    {:ok, client} = Client.mount(host, id)
    assert AgentConversation.Voice.status(client.voice) == :unavailable
    assert {:error, :unavailable} = Client.start_voice(client, :dictation)

    {host, id} = seeded("conv-voice-dictation", 1, voice: {:ok, %{dictation: true}}, features: %{voice: :dictation})
    {:ok, client} = Client.mount(host, id)
    assert {:ok, started} = Client.start_voice(client, :dictation)
    assert started.voice.mode == :dictation
    assert {:error, :unavailable} = Client.start_voice(client, :two_way)

    {host, id} = seeded("conv-voice-denied", 1, voice: {:error, :permission_denied}, features: %{voice: :dictation})
    {:ok, client} = Client.mount(host, id)
    assert AgentConversation.Voice.status(client.voice) == :permission_denied
    assert {:error, :permission_denied} = Client.start_voice(client, :dictation)
  end

  test "a dropped voice connection reports reconnecting instead of failing silently" do
    {host, id} = seeded("conv-voice-drop", 1, voice: {:ok, %{two_way: true}}, features: %{voice: :two_way})
    {:ok, client} = Client.mount(host, id)
    {:ok, client} = Client.start_voice(client, :two_way)

    dropped = Client.disconnect(client)
    assert AgentConversation.Voice.status(dropped.voice) == :reconnecting
    assert dropped.voice.mode == :two_way
  end
end
