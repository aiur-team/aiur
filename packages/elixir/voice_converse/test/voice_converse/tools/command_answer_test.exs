defmodule VoiceConverse.Tools.CommandAnswerTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.{Config, Events, SessionRegistry, Tools}
  alias VoiceConverse.Testing.{FakeProvider, StaticCredentials}
  alias VoiceConverse.Tools.CommandAnswer

  @answered "Command answered."
  @stale "That Command is no longer open."
  @invalid "That is not one of this Command's options."
  @unavailable "Command answers unavailable."

  setup do
    StaticCredentials.put(%{fake: "test-secret"})
    :ok
  end

  describe "advertised schema" do
    test "answer_command appears next to list_open_commands when a CommandSource is configured" do
      specs =
        Tools.specs(%Config{command_source: AnswerSource, briefing_source: CommandAnswerBriefingSource}, %{id: "target"})

      assert [%{name: "list_open_commands"}, spec] =
               Enum.filter(specs, &(&1.name in ["list_open_commands", "answer_command"]))

      assert spec.name == "answer_command"
      assert spec.description =~ "Command"
      assert spec.parameters["type"] == "object"
      assert spec.parameters["required"] == ["id", "choice"]
      assert spec.parameters["additionalProperties"] == false
      assert spec.parameters["properties"]["id"]["type"] == "string"
      assert spec.parameters["properties"]["id"]["minLength"] == 1
      assert spec.parameters["properties"]["id"]["maxLength"] == 200
      assert spec.parameters["properties"]["choice"]["type"] == "string"
      assert spec.parameters["properties"]["choice"]["minLength"] == 1
      assert spec.parameters["properties"]["choice"]["maxLength"] == 500
      assert Enum.sort(Map.keys(spec.parameters["properties"])) == ["choice", "id"]
    end

    test "no CommandSource advertises neither Command tool" do
      specs = Tools.specs(%Config{briefing_source: CommandAnswerBriefingSource}, %{id: "target"})
      refute Enum.any?(specs, &(&1.name in ["list_open_commands", "answer_command"]))
    end

    test "the host allowlist removes answer_command from the specification and from dispatch" do
      config = %Config{
        command_source: AnswerSource,
        briefing_source: CommandAnswerBriefingSource,
        allowed_tools: ["get_status", "list_open_commands"]
      }

      target = %{id: "target", observer: self()}

      refute Enum.any?(Tools.specs(config, target), &(&1.name == "answer_command"))
      assert Enum.any?(Tools.specs(config, target), &(&1.name == "list_open_commands"))

      event = %Events.ToolCall{
        call_id: "call-1",
        name: "answer_command",
        params: %{"id" => "d1", "choice" => "Approve"}
      }

      assert {%{text: "Tool is unavailable in this conversation.", is_error: true}, _state} =
               Tools.dispatch(%{config: config, target: target}, event, &refuse/2)

      refute_received {:answered, _id, _choice, _key}
    end
  end

  describe "answering" do
    test "submits the selected option through the CommandSource" do
      target = %{id: "target", observer: self(), answer: :ok}

      assert %{text: @answered, is_error: false, end?: false} =
               Tools.handle(state(target), event("call-1", "d1", "Approve"))

      assert_received {:answered, "d1", "Approve", key}
      assert key == CommandAnswer.idempotency_key("call-1", "d1")
    end

    test "a re-delivered tool call reuses its idempotency key" do
      target = %{id: "target", observer: self(), answer: :ok}
      call = event("call-1", "d1", "Approve")

      assert %{is_error: false} = Tools.handle(state(target), call)
      assert %{is_error: false} = Tools.handle(state(target), call)

      assert_received {:answered, "d1", "Approve", first}
      assert_received {:answered, "d1", "Approve", second}
      assert first == second
    end

    test "a different call or Command produces a different key" do
      base = CommandAnswer.idempotency_key("call-1", "d1")

      refute CommandAnswer.idempotency_key("call-2", "d1") == base
      refute CommandAnswer.idempotency_key("call-1", "d2") == base
      assert base == CommandAnswer.idempotency_key("call-1", "d1")
    end

    test "the idempotency key is stable across nodes and hides the provider identity" do
      key = CommandAnswer.idempotency_key("call-abc123", "decision-42")

      assert key =~ ~r/\Avc_answer_[A-Za-z0-9_-]{43}\z/
      refute key =~ "call-abc123"
      refute key =~ "decision-42"

      assert key ==
               "vc_answer_" <>
                 Base.url_encode64(:crypto.hash(:sha256, "voice_converse/answer_command\ncall-abc123\ndecision-42"),
                   padding: false
                 )
    end

    test "a stale or conflicting answer says only that the Command is closed" do
      for reason <- [:stale, :conflict, :already_answered, {:conflict, "resolved-elsewhere"}] do
        target = %{id: "target", observer: self(), answer: {:error, reason}}

        assert %{text: @stale, is_error: true} =
                 Tools.handle(state(target), event("call-#{inspect(reason)}", "d1", "Approve"))
      end
    end

    test "an unavailable port reports unavailability without backend detail" do
      for reason <- [:unsupported, :unavailable, :timeout, {:error, :boom}, :something_else] do
        target = %{id: "target", observer: self(), answer: {:error, reason}}

        assert %{text: @unavailable, is_error: true} =
                 Tools.handle(state(target), event("call-#{inspect(reason)}", "d1", "Approve"))
      end
    end

    test "a source that exits or misses the deadline is unavailable rather than answered" do
      assert %{text: @unavailable, is_error: true} =
               Tools.handle(state(%{id: "exit", observer: self(), answer: :exit}), event("call-1", "d1", "Approve"))

      assert %{text: @unavailable, is_error: true} =
               Tools.handle(state(%{id: "slow", observer: self(), answer: :slow}), event("call-1", "d1", "Approve"))
    end

    test "an absent CommandSource keeps answer_command callable but unavailable" do
      assert %{text: @unavailable, is_error: true} =
               Tools.handle(
                 %{config: %Config{briefing_source: CommandAnswerBriefingSource}, target: %{id: "target"}},
                 event("call-1", "d1", "Approve")
               )
    end
  end

  describe "invalid choices" do
    test "a missing, blank or oversized choice is refused before the port is called" do
      for params <- [
            %{"id" => "d1", "choice" => ""},
            %{"id" => "d1", "choice" => "   "},
            %{"id" => "d1"},
            %{"choice" => "Approve"},
            %{"id" => String.duplicate("a", 201), "choice" => "Approve"},
            %{"id" => "d1", "choice" => String.duplicate("a", 501)},
            %{"id" => "d1", "choice" => 42}
          ] do
        target = %{id: "target", observer: self(), answer: :ok}
        call = %Events.ToolCall{call_id: "call-1", name: "answer_command", params: params}

        assert %{text: @invalid, is_error: true} = Tools.handle(state(target), call)
      end

      refute_received {:answered, _id, _choice, _key}
    end

    test "a host-reported invalid choice uses the same neutral text" do
      target = %{id: "target", observer: self(), answer: {:error, :invalid_choice}}

      assert %{text: @invalid, is_error: true} = Tools.handle(state(target), event("call-1", "d1", "Approve"))
    end
  end

  describe "session integration" do
    test "the provider is offered answer_command and its call reaches the CommandSource" do
      {name, id} =
        start_session(%{id: "target", observer: self(), answer: :ok},
          command_source: AnswerSource,
          fake: [open_observer: self(), call_observer: self()]
        )

      assert_receive {:fake_provider, :open_spec, %{tools: tools}}
      assert Enum.any?(tools, &(&1.name == "answer_command"))

      {:ok, session} = SessionRegistry.lookup(name, id)
      ref = :sys.get_state(session).provider_ref
      :ok = FakeProvider.emit(ref, event("call-1", "d1", "Approve"))
      # Returns only after the session has handled the emitted ToolCall.
      _ = :sys.get_state(session)

      assert_receive {:answered, "d1", "Approve", _key}
      assert_receive {:fake_provider, :tool_result, "call-1", %{text: @answered, is_error: false}}
    end

    test "the session allowlist keeps answer_command off the provider's tool list" do
      start_session(%{id: "target", observer: self(), answer: :ok},
        command_source: AnswerSource,
        allowed_tools: ["get_status", "list_open_commands"],
        fake: [open_observer: self()]
      )

      assert_receive {:fake_provider, :open_spec, %{tools: tools}}
      refute Enum.any?(tools, &(&1.name == "answer_command"))
      assert Enum.any?(tools, &(&1.name == "list_open_commands"))
    end
  end

  defp state(target),
    do: %{config: %Config{command_source: AnswerSource, briefing_source: CommandAnswerBriefingSource}, target: target}

  defp event(call_id, id, choice),
    do: %Events.ToolCall{call_id: call_id, name: "answer_command", params: %{"id" => id, "choice" => choice}}

  defp refuse(_state, _event), do: raise("answer_command must be refused before dispatch")

  defp start_session(target, opts) do
    root = Path.join(System.tmp_dir!(), "voice_converse_command_answer_#{System.unique_integer([:positive])}")
    name = Module.concat([VoiceConverse, "CommandAnswerTest#{System.unique_integer([:positive])}"])
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> VoiceConverse.TestCleanup.rm_rf!(root) end)

    {:ok, config} =
      Config.new(
        name: name,
        transcript_root: root,
        credentials: StaticCredentials,
        briefing_source: CommandAnswerBriefingSource,
        command_source: Keyword.fetch!(opts, :command_source),
        allowed_tools: Keyword.get(opts, :allowed_tools),
        provider: {FakeProvider, []},
        llm: "test-model",
        cloud_disclosure_accepted: true
      )

    start_supervised!(VoiceConverse.child_spec(config))

    fake =
      opts
      |> Keyword.fetch!(:fake)
      |> Keyword.put(:script, [%Events.ProviderConversationId{id: "provider-session"}])

    {:ok, id} = VoiceConverse.start_session(name, target, client: self(), provider: {FakeProvider, fake})
    {name, id}
  end
end

defmodule AnswerSource do
  @moduledoc false
  @behaviour VoiceConverse.Ports.CommandSource

  @impl true
  def open(target), do: {:ok, Map.get(target, :commands, [])}

  @impl true
  def answer(target, id, choice, key) do
    if observer = target[:observer], do: send(observer, {:answered, id, choice, key})

    case Map.get(target, :answer, :ok) do
      :exit ->
        exit(:boom)

      :slow ->
        Process.sleep(500)
        :ok

      result ->
        result
    end
  end

  @impl true
  def subscribe(_target, _pid), do: :unsupported
end

defmodule CommandAnswerBriefingSource do
  @moduledoc false
  @behaviour VoiceConverse.Ports.BriefingSource

  @impl true
  def describe_target(target), do: %{id: target.id, kind: :test, title: "Test target"}
  @impl true
  def brief(_target), do: {:ok, %VoiceConverse.Briefing{}}
  @impl true
  def details(_target, _section, _opts), do: {:ok, ""}
  @impl true
  def sections(_target), do: []
  @impl true
  def subscribe(_target, _pid), do: :unsupported
  @impl true
  def alive?(_target), do: :unknown
end
