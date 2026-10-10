defmodule Aiur.Codex.TurnLoopTestSupport do
  @moduledoc false

  import ExUnit.Assertions, only: [flunk: 1]

  alias Aiur.AppServer.{ProviderTurnLedger, TurnState}
  alias Aiur.Codex.CodingAgent
  alias Aiur.ProviderAccountGeneration

  def base_state(on_safe_checkpoint \\ fn _checkpoint -> :noop end) do
    test_pid = self()

    %{
      on_message: fn message -> send(test_pid, {:event, message.event}) end,
      on_safe_checkpoint: on_safe_checkpoint,
      tool_executor: fn _tool, _arguments -> %{"success" => true} end,
      auto_approve_requests: false,
      pending_operator_requests: %{},
      outstanding_turns: 1,
      pending_interrupt_request_id: nil,
      interrupt_action: nil,
      pause_request_id: nil,
      current_turn_id: "turn-1",
      issue_identifier: "ISSUE-1",
      turn_started?: false,
      active_turn_ids: MapSet.new(["turn-1"]),
      accepted_turn_ids: MapSet.new(),
      retired_turn_ids: MapSet.new(),
      anonymous_completion_consumed?: false,
      interrupt_acknowledged?: false,
      interrupt_idle_seen?: false,
      backend: CodingAgent
    }
  end

  def start_owner(opts) do
    {:ok, owner} = ProviderAccountGeneration.start_link(Keyword.put(opts, :name, nil))
    owner
  end

  def stored_turn_state(store, turn_id) do
    base_state()
    |> Map.merge(ProviderTurnLedger.start_turn(store))
    |> Map.put(:current_turn_id, turn_id)
    |> TurnState.initialize_turn_tracking()
  end

  def turn_completed_payload(turn_id, status \\ "completed") do
    %{
      "method" => "turn/completed",
      "params" => %{"turn" => %{"id" => turn_id, "status" => status}}
    }
  end

  def open_cat_port do
    Port.open(
      {:spawn_executable, System.find_executable("cat") |> String.to_charlist()},
      [:binary, :exit_status, {:line, 64_000}]
    )
  end

  def read_one_frame(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        Jason.decode!(line)

      {^port, {:data, line}} when is_binary(line) ->
        line
        |> String.trim_trailing()
        |> Jason.decode!()
    after
      1_000 -> flunk("no frame read from port within 1s")
    end
  end

  def close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
