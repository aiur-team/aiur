defmodule Aiur.AppServer.Transport do
  @moduledoc "Port operations shared by direct and detached app-server transports."

  alias Aiur.AppServer.RelayPort

  @type t :: port() | pid()

  @spec command(t(), binary()) :: true
  def command(port, line) when is_port(port), do: Port.command(port, line)
  def command(pid, line) when is_pid(pid), do: relay_call(pid, {:command, line})

  @doc "Acknowledges one relay frame after the turn loop has processed it."
  @spec acknowledge(t()) :: :ok
  def acknowledge(port) when is_port(port), do: :ok
  def acknowledge(pid) when is_pid(pid), do: relay_call(pid, :acknowledge)

  @doc false
  @spec manual_acknowledgements(t()) :: :ok
  def manual_acknowledgements(port) when is_port(port), do: :ok
  def manual_acknowledgements(pid) when is_pid(pid), do: relay_call(pid, :manual_acknowledgements)

  @spec close(t()) :: true
  def close(port) when is_port(port), do: Port.close(port)
  def close(pid) when is_pid(pid), do: relay_call(pid, :close)

  @doc """
  Kills processes the relay adopted because their launcher exited: tool
  commands that left the provider's session (#4730). The direct Port has
  no subreaper, so it has nothing to reap.
  """
  @spec reap_orphans(t()) :: :ok
  def reap_orphans(port) when is_port(port), do: :ok

  # A cast: turn boundaries must never wait on, or crash with, the relay.
  def reap_orphans(pid) when is_pid(pid), do: GenServer.cast(pid, :reap_orphans)

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
