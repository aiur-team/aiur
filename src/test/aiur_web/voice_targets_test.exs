defmodule AiurWeb.VoiceTargetsTest do
  # The resolver binding is application config, so these tests run alone.
  use ExUnit.Case, async: false

  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.OperatorControlCenter.VoiceTargetResolver, as: DashboardResolver
  alias AiurWeb.{VoiceTargetResolver, VoiceTargets}

  defmodule OddResolver do
    @moduledoc false
    @behaviour AiurWeb.VoiceTargetResolver
    @impl true
    def worker(_ticket), do: :maybe
    @impl true
    def command(_decision_id, _expected_version), do: {:error, :target_exploded}
  end

  defmodule RaisingResolver do
    @moduledoc false
    @behaviour AiurWeb.VoiceTargetResolver
    @impl true
    def worker(_ticket), do: raise("resolver bug")
    @impl true
    def command(_decision_id, _expected_version), do: throw(:resolver_bug)
  end

  defmodule FakeDecisionStore do
    @moduledoc false
    use GenServer

    def start_link(decisions), do: GenServer.start_link(__MODULE__, decisions)

    @impl true
    def init(decisions), do: {:ok, decisions}

    @impl true
    def handle_call({:retained_lookup, decision_id}, _from, decisions) do
      {:reply, {:ok, %{decision: Map.get(decisions, decision_id), health: :writable}}, decisions}
    end
  end

  setup do
    previous = Application.fetch_env(:aiur, :voice_target_resolver)
    Application.put_env(:aiur, :voice_target_resolver, DashboardResolver)

    on_exit(fn ->
      case previous do
        {:ok, resolver} -> Application.put_env(:aiur, :voice_target_resolver, resolver)
        :error -> Application.delete_env(:aiur, :voice_target_resolver)
      end
    end)
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
      # No process holds this name, so every call to the store exits.
      EndpointStubs.put(decision_store: :voice_targets_test_missing_store)

      assert {:error, %{reason_code: "unknown"}} = VoiceTargets.validate(command("d1", nil), "command_response")
    end
  end

  # A malformed store reply must still refuse with a code, not crash the join.
  test "a malformed store reply is unknown" do
    store(%{"d1" => :not_a_decision})
    assert {:error, %{reason_code: "unknown"}} = VoiceTargets.validate(command("d1", nil), "command_response")
  end

  test "surfaces whose tickets have not landed are refused" do
    running(["ENG-7"])

    for surface <- ["command_revision", "conversation_panel"] do
      assert {:error, %{reason_code: "invalid_payload"}} = VoiceTargets.validate(@worker, surface)
    end
  end

  test "a resolver answer outside the contract is unknown" do
    Application.put_env(:aiur, :voice_target_resolver, OddResolver)
    assert {:error, %{reason_code: "unknown"}} = VoiceTargets.validate(@worker, "agent_composer")
    assert {:error, %{reason_code: "unknown"}} = VoiceTargets.validate(command("d1", nil), "command_response")
  end

  test "a resolver that raises or exits is unknown, never a missing target" do
    Application.put_env(:aiur, :voice_target_resolver, RaisingResolver)
    assert {:error, %{reason_code: "unknown"}} = VoiceTargets.validate(@worker, "agent_composer")
    assert {:error, %{reason_code: "unknown"}} = VoiceTargets.validate(command("d1", nil), "command_response")
  end

  # Without a component that owns the rules, voice must not guess a target is writable.
  test "with no resolver bound, no target can be addressed" do
    Application.delete_env(:aiur, :voice_target_resolver)
    assert VoiceTargetResolver.impl() == VoiceTargetResolver.Unbound
    assert {:error, %{reason_code: "unsupported_target"}} = VoiceTargets.validate(@worker, "agent_composer")
    assert {:error, %{reason_code: "unsupported_target"}} = VoiceTargets.validate(command("d1", nil), "command_response")
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

  defp decision(status, version) do
    struct!(Aiur.Decision,
      decision_id: "d",
      version: version,
      ticket: "ENG-7",
      source: "agent",
      authority: :human_required,
      urgency: :normal,
      blocking: false,
      reversibility: :reversible,
      question: "Ship it?",
      context: "",
      options: [],
      artifacts: [],
      created_at: ~U[2026-10-01 00:00:00Z],
      content_hash: "hash",
      decision_status: status
    )
  end
end
