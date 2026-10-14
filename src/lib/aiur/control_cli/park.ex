defmodule Aiur.ControlCLI.Park do
  @moduledoc false

  alias Aiur.ControlCLI.Reasons
  import Aiur.ControlCLI.Protocol, only: [exit_marker: 1, guarded: 2]

  @spec run([String.t()]) :: :ok
  def run(targets) do
    guarded("park", fn ->
      results = Enum.map(targets, fn id -> {id, GenServer.call(Aiur.Orchestrator, {:park_agent, to_string(id)}, 5_000)} end)

      Enum.each(results, fn
        {id, {:ok, :pending}} -> IO.puts("parking ##{id}; tracker marker write pending")
        {id, {:ok, :already_parked}} -> IO.puts("##{id} already parked")
        {id, {:error, reason}} -> IO.puts(:stderr, "✗ ##{id} could not be parked: #{Reasons.format_reason(reason)}")
      end)

      exit_marker(if Enum.any?(results, &match?({_, {:error, _}}, &1)), do: 1, else: 0)
    end)
  end
end
