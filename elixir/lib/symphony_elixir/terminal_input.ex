defmodule SymphonyElixir.TerminalInput do
  @moduledoc """
  Reads foreground terminal keys and forwards dashboard navigation commands.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.StatusDashboard

  @type state :: %{reader_pid: pid(), dashboard: GenServer.name(), restore_terminal?: boolean()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @impl true
  def init(opts) do
    dashboard = Keyword.get(opts, :dashboard, StatusDashboard)
    input_fun = Keyword.get(opts, :input_fun, fn -> IO.binread(:stdio, 1) end)
    skip_raw_mode? = Keyword.get(opts, :skip_raw_mode, false)
    Process.flag(:trap_exit, true)

    case enter_raw_mode(skip_raw_mode?) do
      :ok ->
        parent = self()
        reader_pid = spawn_link(fn -> read_loop(parent, dashboard, input_fun) end)
        {:ok, %{reader_pid: reader_pid, dashboard: dashboard, restore_terminal?: not skip_raw_mode?}}

      {:error, reason} ->
        Logger.warning("Interactive terminal input disabled: #{reason}")
        :ignore
    end
  end

  @impl true
  def terminate(_reason, %{restore_terminal?: true}) do
    restore_terminal()
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_info({:EXIT, pid, reason}, %{reader_pid: pid} = state) do
    if reason != :normal do
      Logger.warning("Interactive terminal input reader exited: #{inspect(reason)}; continuing without input")
    end

    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _other_pid_or_port, _reason}, state) do
    # System.cmd's Port (and any other linked-then-exited resource) sends an
    # EXIT signal that trap_exit turns into a message. Anything that isn't the
    # reader is not our problem.
    {:noreply, state}
  end

  defp read_loop(parent, dashboard, input_fun) do
    case input_fun.() do
      :eof ->
        :ok

      byte ->
        Logger.debug("TerminalInput received byte: #{inspect(byte)}")
        dispatch_byte(byte, parent, dashboard, input_fun)
    end
  end

  defp dispatch_byte("\e", parent, dashboard, input_fun) do
    case input_fun.() do
      :eof ->
        StatusDashboard.close_log(dashboard)
        :ok

      "[" ->
        read_csi(dashboard, input_fun, "")
        read_loop(parent, dashboard, input_fun)

      other ->
        # Bare ESC: close the log pane and process whatever followed as a normal key.
        StatusDashboard.close_log(dashboard)
        dispatch_byte(other, parent, dashboard, input_fun)
    end
  end

  defp dispatch_byte(<<3>>, _parent, _dashboard, _input_fun), do: System.stop(0)
  defp dispatch_byte("q", _parent, _dashboard, _input_fun), do: System.stop(0)

  defp dispatch_byte(byte, parent, dashboard, input_fun) when byte in [" ", "\r", "\n"] do
    StatusDashboard.open_log(dashboard)
    read_loop(parent, dashboard, input_fun)
  end

  defp dispatch_byte("j", parent, dashboard, input_fun) do
    StatusDashboard.select_next(dashboard)
    read_loop(parent, dashboard, input_fun)
  end

  defp dispatch_byte("k", parent, dashboard, input_fun) do
    StatusDashboard.select_previous(dashboard)
    read_loop(parent, dashboard, input_fun)
  end

  defp dispatch_byte(_other, parent, dashboard, input_fun) do
    read_loop(parent, dashboard, input_fun)
  end

  defp read_csi(dashboard, input_fun, params) do
    case input_fun.() do
      :eof ->
        :ok

      byte ->
        if csi_final?(byte) do
          dispatch_csi(dashboard, params, byte)
        else
          read_csi(dashboard, input_fun, params <> byte)
        end
    end
  end

  defp csi_final?(<<c>>) when c in ?A..?Z or c in ?a..?z or c == ?~, do: true
  defp csi_final?(_), do: false

  defp dispatch_csi(dashboard, "", "A"), do: StatusDashboard.select_previous(dashboard)
  defp dispatch_csi(dashboard, "", "B"), do: StatusDashboard.select_next(dashboard)
  defp dispatch_csi(dashboard, "", "D"), do: StatusDashboard.close_log(dashboard)
  defp dispatch_csi(dashboard, "5", "~"), do: StatusDashboard.scroll_log_up(dashboard)
  defp dispatch_csi(dashboard, "6", "~"), do: StatusDashboard.scroll_log_down(dashboard)
  defp dispatch_csi(_dashboard, _params, _final), do: :ok

  defp enter_raw_mode(true), do: :ok

  defp enter_raw_mode(false) do
    with {:ok, device} <- tty_device() do
      run_stty(device, ["-icanon", "-echo", "-isig", "-ixon", "min", "1", "time", "0"])
    end
  end

  defp restore_terminal do
    case tty_device() do
      {:ok, device} -> run_stty(device, ["sane"])
      _ -> :ok
    end

    :ok
  end

  defp tty_device do
    case File.read_link("/proc/self/fd/0") do
      {:ok, "/dev/" <> _ = path} -> {:ok, path}
      {:ok, path} -> {:error, "stdin is not a tty (#{path})"}
      {:error, reason} -> {:error, "could not resolve controlling tty: #{inspect(reason)}"}
    end
  end

  defp run_stty(device, args) do
    case System.cmd("stty", ["-F", device] ++ args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, "stty #{Enum.join(args, " ")} on #{device} exited with status #{status}: #{String.trim(output)}"}
    end
  rescue
    error in ErlangError -> {:error, Exception.message(error)}
  end
end
