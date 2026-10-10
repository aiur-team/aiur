defmodule Aiur.AppServer.Transport do
  @moduledoc "Port operations shared by direct and detached app-server transports."

  alias Aiur.AppServer.RelayPort

  @type t :: port() | pid()

  @spec command(t(), binary()) :: true
  def command(port, line) when is_port(port), do: Port.command(port, line)
  def command(pid, line) when is_pid(pid), do: relay_call(pid, {:command, line})

  @spec close(t()) :: true
  def close(port) when is_port(port), do: Port.close(port)
  def close(pid) when is_pid(pid), do: relay_call(pid, :close)

  @spec os_pid(t()) :: {:os_pid, pos_integer()} | nil
  def os_pid(port) when is_port(port), do: Port.info(port, :os_pid)

  def os_pid(pid) when is_pid(pid) do
    case metadata(pid) do
      %{provider_pid: provider_pid} -> {:os_pid, provider_pid}
      _ -> nil
    end
  end

  @spec metadata(t()) :: map()
  def metadata(port) when is_port(port), do: %{}

  def metadata(pid) when is_pid(pid) do
    RelayPort.call(pid, :metadata)
  catch
    :exit, _reason -> %{}
  end

  defp relay_call(pid, request) do
    RelayPort.call(pid, request)
  catch
    :exit, reason -> raise ArgumentError, "relay transport closed: #{inspect(reason)}"
  end
end
