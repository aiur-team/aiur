defmodule Aiur.AgentControlCLI.Redispatch do
  @moduledoc false

  alias Aiur.Orchestrator.Client

  @spec redispatch([String.t()], String.t() | nil) :: :ok | {:error, :redispatch_failed}
  def redispatch(targets, backend) when is_list(targets) do
    results = Enum.map(targets, fn target -> {target, Client.redispatch(target, backend)} end)
    Enum.each(results, &print_result/1)

    if Enum.any?(results, fn {_target, result} -> match?({:error, _}, result) end),
      do: {:error, :redispatch_failed},
      else: :ok
  end

  @doc false
  @spec format_result(String.t(), {:ok, :redispatched} | {:error, term()}) :: String.t()
  def format_result(target, {:ok, :redispatched}), do: "aiur: redispatch started for ticket #{target}"

  def format_result(target, {:error, :not_running}),
    do: "aiur: ticket #{target} is not running; use `aiur --todo #{target}` to queue it"

  def format_result(target, {:error, reason}),
    do: "aiur: redispatch failed for ticket #{target} (#{inspect(reason)})"

  defp print_result({target, result}) do
    message = format_result(target, result)
    if match?({:error, _}, result), do: IO.puts(:stderr, message), else: IO.puts(message)
  end
end
