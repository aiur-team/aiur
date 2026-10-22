defmodule AiurWeb.VoiceTargetsTest do
  use ExUnit.Case, async: true

  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.VoiceTargets

  defmodule FakeDecisionStore do
    @moduledoc false
    use GenServer

    def start_link(decisions), do: GenServer.start_link(__MODULE__, decisions)

    @impl true
    def init(decisions), do: {:ok, decisions}

    @impl true
    def handle_call({:get, decision_id}, _from, decisions) do
      case Map.fetch(decisions, decision_id) do
        {:ok, decision} -> {:reply, {:ok, decision}, decisions}
        :error -> {:reply, {:error, :not_found}, decisions}
      end
    end
  end

  @worker %{kind: :worker, ticket: "ENG-7", instance_id: nil}

  describe "worker targets follow the agent drawer's Send rule" do
    test "a running agent with a unique identifier is a valid target" do
      running(["ENG-7", "ENG-8"])
      assert :ok = VoiceTargets.validate(@worker, "agent_composer")
    end

    test "an agent that is not running is refused before recording starts" do
      running(["ENG-8"])

      assert {:error, %{reason_code: "target_not_found", reason: "Agent is no longer running."}} =
               VoiceTargets.validate(@worker, "agent_composer")
    end

    test "an unpublished fleet snapshot has no running agents" do
      EndpointStubs.put(voice_target_payload_fun: fn -> %{error: %{code: "snapshot_unpublished"}} end)
      assert {:error, %{reason_code: "target_not_found"}} = VoiceTargets.validate(@worker, "agent_composer")
    end

    # Two agents share the identifier, so text dictated for one could reach the other.
    test "an identifier shared by two running agents is not writable" do
      running(["ENG-7", "ENG-7"])
      assert {:error, %{reason_code: "target_not_writable"}} = VoiceTargets.validate(@worker, "agent_composer")
    end

    test "a payload that cannot load is unknown, not a missing agent" do
      EndpointStubs.put(voice_target_payload_fun: fn -> exit(:timeout) end)
      assert {:error, %{reason_code: "unknown"}} = VoiceTargets.validate(@worker, "agent_composer")
    end
  end

  describe "command targets must still take an answer at the version the client saw" do
    test "an open Command at the expected version is valid" do
      store(%{"d1" => decision(:open, 4)})
      assert :ok = VoiceTargets.validate(command("d1", 4), "command_response")
      assert :ok = VoiceTargets.validate(command("d1", nil), "command_response")
    end

    test "deferred and dismissed Commands still take an answer" do
      store(%{"d1" => decision(:deferred, 1), "d2" => decision(:dismissed, 1)})
      assert :ok = VoiceTargets.validate(command("d1", nil), "command_response")
      assert :ok = VoiceTargets.validate(command("d2", nil), "command_response")
    end

    test "an expired blocking Command with no answer is still answerable, as on the dashboard" do
      store(%{"d1" => %{decision(:expired, 1) | blocking: true}})
      assert :ok = VoiceTargets.validate(command("d1", nil), "command_response")
    end

    test "a resolved Command is stale" do
      store(%{"d1" => decision(:resolved, 2)})
      assert {:error, %{reason_code: "target_stale"}} = VoiceTargets.validate(command("d1", nil), "command_response")
    end

    test "a Command whose version moved is stale" do
      store(%{"d1" => decision(:open, 4)})
      assert {:error, %{reason_code: "target_stale"}} = VoiceTargets.validate(command("d1", 3), "command_response")
    end

    test "an unknown Command is not found" do
      store(%{})
      assert {:error, %{reason_code: "target_not_found"}} = VoiceTargets.validate(command("gone", nil), "command_response")
    end

    # The store's state is unknowable: reporting the Command as gone would be a guess.
    test "a store exit is unknown, not target_not_found" do
      {:ok, dead} = Task.start(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}
      EndpointStubs.put(decision_store: dead)

      assert {:error, %{reason_code: "unknown"}} = VoiceTargets.validate(command("d1", nil), "command_response")
    end
  end

  # A malformed store reply must still refuse with a code, not crash the join.
  test "a store reply that raises is unknown" do
    store(%{"d1" => :not_a_decision})
    assert {:error, %{reason_code: "unknown"}} = VoiceTargets.validate(command("d1", nil), "command_response")
  end

  test "surfaces whose tickets have not landed are refused" do
    running(["ENG-7"])

    for surface <- ["command_revision", "conversation_panel"] do
      assert {:error, %{reason_code: "invalid_payload"}} = VoiceTargets.validate(@worker, surface)
    end
  end

  test "an executor target is unsupported in this build" do
    assert {:error, %{reason_code: "unsupported_target"}} =
             VoiceTargets.validate(%{kind: :executor, instance_id: nil}, "executor_composer")
  end

  test "a surface that does not own the target kind is invalid" do
    running(["ENG-7"])
    assert {:error, %{reason_code: "invalid_payload"}} = VoiceTargets.validate(@worker, "command_response")
    assert {:error, %{reason_code: "invalid_payload"}} = VoiceTargets.validate(command("d1", nil), "agent_composer")
  end

  defp running(identifiers) do
    payload = %{fleet: %{running: Enum.map(identifiers, &%{issue_identifier: &1})}}
    EndpointStubs.put(voice_target_payload_fun: fn -> payload end)
  end

  defp store(decisions) do
    pid = start_supervised!({FakeDecisionStore, decisions})
    EndpointStubs.put(decision_store: pid)
  end

  defp command(decision_id, expected_version),
    do: %{kind: :command, decision_id: decision_id, expected_version: expected_version, instance_id: nil}

  defp decision(status, version), do: %{decision_status: status, version: version, blocking: false, answer: nil}
end
