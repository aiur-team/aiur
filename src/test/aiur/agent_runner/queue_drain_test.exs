defmodule Aiur.AgentRunner.QueueDrainTest do
  use ExUnit.Case, async: false
  @moduletag :r7_characterization

  alias Aiur.AgentRunner.QueueDrain
  alias Aiur.AlertFeed
  alias Aiur.Issue

  defmodule FakeDecisionStore do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, %{report: Keyword.fetch!(opts, :report), reply: Keyword.fetch!(opts, :reply)}}

    @impl true
    def handle_call({:validate_delivery, item}, _from, state) do
      send(state.report, {:decision_delivery_prepared, item})
      {:reply, state.reply, state}
    end

    def handle_call({:transport_transition, :delivered, item, nil}, _from, state) do
      send(state.report, {:decision_delivery, item})
      {:reply, state.reply, state}
    end
  end

  describe "claim_after_queue_update/3" do
    test "returns :ignored when deliver_now? is false" do
      assert QueueDrain.claim_after_queue_update(self(), "QD-01", false) == :ignored
    end
  end

  describe "prepare_operator_delivery/2" do
    test "returns :ok for a non-operator-message item" do
      item = %{category: :coordination_event, id: 1}
      issue = %Issue{identifier: "QD-01", id: "gid-qd01"}

      assert QueueDrain.prepare_operator_delivery(item, issue) == :ok
    end

    test "returns :ok when issue has no binary identifier" do
      item = %{category: :operator_message, id: 1}
      issue = %Issue{identifier: nil, id: "gid-qd02"}

      assert QueueDrain.prepare_operator_delivery(item, issue) == :ok
    end

    test "validates correlated delivery without marking it provider-delivered" do
      {:ok, store} = FakeDecisionStore.start_link(report: self(), reply: {:ok, :accepted})
      issue = %Issue{identifier: "QD-09", id: "gid-qd09"}

      assert QueueDrain.prepare_operator_delivery(correlated_item(), issue, store) == :ok
      assert_receive {:decision_delivery_prepared, %{action_id: "act_9"}}, 1000
      refute_receive {:decision_delivery, _}, 100
    end

    test "bounds correlation retries and keeps terminal attention open until recovery", %{log_root: log_root} do
      {:ok, store} = FakeDecisionStore.start_link(report: self(), reply: {:error, :store_unavailable})
      issue = %Issue{identifier: "QD-09", id: "gid-qd09"}
      topic = "ticket.QD-09.agent.attention.decision-delivery-correlation-act-9"

      assert QueueDrain.prepare_operator_delivery(correlated_item(), issue, store) ==
               {:error, {:retry, :store_unavailable}}

      assert case_attention_alerts(log_root, topic) == []

      exhausted = Map.put(correlated_item(), :delivery_attempts, 3)

      assert QueueDrain.prepare_operator_delivery(exhausted, issue, store) ==
               {:error, {:failed, :store_unavailable}}

      assert [%{"topic" => ^topic}] = case_attention_alerts(log_root, topic)

      {:ok, recovered_store} = FakeDecisionStore.start_link(report: self(), reply: {:ok, :accepted})
      assert QueueDrain.prepare_operator_delivery(correlated_item(), issue, recovered_store) == :ok
      assert case_attention_alerts(log_root, topic) == []
    end
  end

  describe "record_provider_delivery/3" do
    test "persists correlated delivery only after provider acknowledgement" do
      {:ok, store} = FakeDecisionStore.start_link(report: self(), reply: {:ok, :accepted})
      issue = %Issue{identifier: "QD-09", id: "gid-qd09"}

      assert QueueDrain.record_provider_delivery(correlated_item(), issue, store) == :ok
      assert_receive {:decision_delivery, %{action_id: "act_9"}}, 1000
    end
  end

  setup do
    original_log_file = Application.get_env(:aiur, :log_file)
    log_root = Aiur.TestSupport.tmp_root!("aiur-queue-drain")
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
    Aiur.TestSupport.put_runtime_state_dir!(log_root)

    on_exit(fn ->
      if original_log_file do
        Application.put_env(:aiur, :log_file, original_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end

      # A late log writer can recreate an entry between rm_rf's directory
      # listing and final rmdir under CI load. As documented in #461/#480,
      # tolerate that race for this unique test root instead of raising.
      Aiur.TestCleanup.rm_rf!(log_root, unset: [:runtime_state_dir])
    end)

    %{log_root: log_root}
  end

  defp correlated_item do
    %{
      category: :operator_message,
      id: 9,
      action_id: "act_9",
      correlation: %{
        decision_id: "dec_9",
        decision_version: 1,
        action_id: "act_9",
        attempt_id: "act_9:1"
      }
    }
  end

  defp case_attention_alerts(log_root, topic) do
    # Other tests can emit into the VM-global runtime log root concurrently.
    AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true)
    |> Enum.filter(&(&1["topic"] == topic))
  end
end
