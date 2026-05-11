defmodule SymphonyElixir.TerminalInput do
  @moduledoc """
  Reads foreground terminal keys and forwards dashboard navigation commands.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.StatusDashboard

  @type state :: %{reader_pid: pid(), dashboard: GenServer.name()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @impl true
  def init(opts) do
    dashboard = Keyword.get(opts, :dashboard, StatusDashboard)
    Process.flag(:trap_exit, true)

    case enter_raw_mode() do
      :ok ->
        parent = self()
        reader_pid = spawn_link(fn -> read_loop(parent, dashboard) end)
        {:ok, %{reader_pid: reader_pid, dashboard: dashboard}}

      {:error, reason} ->
        Logger.warning("Interactive terminal input disabled: #{reason}")
        :ignore
    end
  end

  @impl true
  def terminate(_reason, _state) do
    restore_terminal()
    :ok
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{reader_pid: pid} = state) do
    {:stop, reason, state}
  end

  defp read_loop(parent, dashboard) do
    case IO.getn("", 1) do
      <<3>> ->
        restore_terminal()
        System.stop(0)

      "q" ->
        restore_terminal()
        System.stop(0)

      "j" ->
        StatusDashboard.select_next(dashboard)
        read_loop(parent, dashboard)

      "k" ->
        StatusDashboard.select_previous(dashboard)
        read_loop(parent, dashboard)

      "\e" ->
        read_escape_sequence(dashboard)
        read_loop(parent, dashboard)

      :eof ->
        send(parent, {:EXIT, self(), :normal})

      _other ->
        read_loop(parent, dashboard)
    end
  end

  defp read_escape_sequence(dashboard) do
    case {IO.getn("", 1), IO.getn("", 1)} do
      {"[", "A"} -> StatusDashboard.select_previous(dashboard)
      {"[", "B"} -> StatusDashboard.select_next(dashboard)
      _ -> :ok
    end
  end

  defp enter_raw_mode do
    case System.cmd("stty", ["raw", "-echo"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, String.trim(output)}
    end
  rescue
    error in ErlangError ->
      {:error, Exception.message(error)}
  end

  defp restore_terminal do
    System.cmd("stty", ["sane"], stderr_to_stdout: true)
    :ok
  rescue
    _error in ErlangError -> :ok
  end
end
