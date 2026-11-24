defmodule Aiur.ControlCLI.Park do
  @moduledoc false

  alias Aiur.ControlCLI.Reasons
  import Aiur.ControlCLI.Protocol, only: [control_error: 1, exit_marker: 1, guarded: 2]

  # A pause run just before reaches the worker within seconds; park waits for it.
  @pause_wait_attempts 30

  @spec run([String.t()]) :: :ok
  def run(targets) do
    guarded("park", fn ->
      results = Enum.map(targets, fn id -> {id, park(to_string(id), @pause_wait_attempts)} end)

      Enum.each(results, fn
        {id, {:ok, :pending}} -> IO.puts("parking ##{id}; tracker marker write pending")
        {id, {:ok, :already_parked}} -> IO.puts("##{id} already parked")
        {id, {:error, reason}} -> control_error("✗ ##{id} could not be parked: #{Reasons.format_reason(reason)}")
      end)

      exit_marker(if Enum.any?(results, &match?({_, {:error, _}}, &1)), do: 1, else: 0)
    end)
  end

  @doc false
  @spec park(String.t(), non_neg_integer(), (String.t() -> term())) :: term()
  def park(id, attempts, call \\ &call/1) do
    case call.(id) do
      {:error, :pause_pending} when attempts > 1 ->
        Process.sleep(1_000)
        park(id, attempts - 1, call)

      result ->
        result
    end
  end

  defp call(id), do: GenServer.call(Aiur.Project.whereis(Aiur.Orchestrator), {:park_agent, id}, 5_000)
end
