defmodule Aiur.AgentControlCLI.Redispatch do
  @moduledoc false

  alias Aiur.Orchestrator.Client

  @spec redispatch([String.t()], String.t() | nil) :: :ok | {:error, :redispatch_failed}
  def redispatch(targets, backend) when is_list(targets) do
    results = Enum.map(targets, &Client.redispatch(&1, backend))
    Enum.each(results, &print_result/1)
    if Enum.any?(results, &match?({:error, _}, &1)), do: {:error, :redispatch_failed}, else: :ok
  end

  defp print_result({:ok, :redispatched}), do: IO.puts("aiur: redispatch started for ticket")
  defp print_result({:error, reason}), do: IO.puts(:stderr, "aiur: redispatch failed (#{inspect(reason)})")
end
