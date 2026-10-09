defmodule AiurWeb.Build.Read do
  @moduledoc false
  alias AiurWeb.Build.Payload
  alias AiurWeb.FinancialDataAccess

  @spec source_opts(Phoenix.LiveView.Socket.t()) :: keyword()
  def source_opts(socket) do
    context = FinancialDataAccess.context(socket)
    financial = if FinancialDataAccess.authorize(context) == :ok, do: {:ok, context}, else: :locked
    [time_zone: socket.assigns.build_time_zone, financial: financial]
  end

  @spec safe_read((-> term())) :: {:ok, map()} | {:error, term()}
  def safe_read(fun) do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          _ -> {:error, :crashed}
        catch
          _, _ -> {:error, :crashed}
        end
      end)

    result(Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill))
  end

  @spec locked_usage() :: map()
  def locked_usage do
    FinancialDataAccess.locked_capability() |> Map.delete(:version) |> Payload.scrub()
  end

  defp result({:ok, {:ok, data}}) when is_map(data), do: {:ok, data}
  defp result({:ok, {:error, reason}}), do: {:error, reason}
  defp result(nil), do: {:error, :timeout}
  defp result({:exit, _}), do: {:error, :crashed}
  defp result(_), do: {:error, :invalid}
end
