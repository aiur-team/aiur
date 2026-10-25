defmodule Aiur.BrowserHarness.FixtureEndpointStart do
  @moduledoc false

  @port_retries 5

  def start(start_fun, port, retries \\ @port_retries) do
    attempt(start_fun, port, retries, {:error, :eaddrinuse})
  end

  defp attempt(_start_fun, _port, 0, last_error), do: last_error

  defp attempt(start_fun, port, retries, _last_error) do
    case start_attempt(start_fun, port) do
      {:error, reason} = error ->
        if address_in_use?(reason), do: attempt(start_fun, 0, retries - 1, error), else: error

      result ->
        result
    end
  end

  defp start_attempt(start_fun, port) do
    # Endpoint.start_link reports listener failures through a linked exit signal.
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      result =
        try do
          start_fun.(port)
        catch
          :exit, reason -> {:error, reason}
        end

      receive do
        {:EXIT, _pid, reason} ->
          if address_in_use?(reason), do: {:error, reason}, else: exit(reason)
      after
        0 -> result
      end
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp address_in_use?(:eaddrinuse), do: true
  defp address_in_use?(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.any?(&address_in_use?/1)
  defp address_in_use?(value) when is_list(value), do: Enum.any?(value, &address_in_use?/1)
  defp address_in_use?(_value), do: false
end
