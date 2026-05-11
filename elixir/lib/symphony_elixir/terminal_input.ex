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
      restart: :transient
    }
  end

  @impl true
  def init(opts) do
    dashboard = Keyword.get(opts, :dashboard, StatusDashboard)
    input_fun = Keyword.get(opts, :input_fun)
    skip_raw_mode? = Keyword.get(opts, :skip_raw_mode, false)
    Process.flag(:trap_exit, true)

    case enter_raw_mode(skip_raw_mode?) do
      :ok ->
        parent = self()
        reader_pid = spawn_link(fn -> read_tty_loop(parent, dashboard, input_fun) end)
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
    {:stop, reason, state}
  end

  defp read_tty_loop(parent, dashboard, nil) do
    case :file.open(~c"/dev/tty", [:read, :raw, :binary]) do
      {:ok, tty} ->
        read_loop(parent, dashboard, fn -> read_one_byte(tty) end)

      {:error, reason} ->
        send(parent, {:EXIT, self(), {:tty_open_failed, reason}})
    end
  end

  defp read_tty_loop(parent, dashboard, input_fun) when is_function(input_fun, 0) do
    read_loop(parent, dashboard, input_fun)
  end

  defp read_one_byte(tty) do
    case :file.read(tty, 1) do
      {:ok, byte} -> byte
      :eof -> :eof
      {:error, _reason} -> :eof
    end
  end

  defp read_loop(parent, dashboard, input_fun) do
    case input_fun.() do
      <<3>> ->
        restore_terminal()
        System.stop(0)

      "q" ->
        restore_terminal()
        System.stop(0)

      "j" ->
        StatusDashboard.select_next(dashboard)
        read_loop(parent, dashboard, input_fun)

      "k" ->
        StatusDashboard.select_previous(dashboard)
        read_loop(parent, dashboard, input_fun)

      "\e" ->
        read_escape_sequence(dashboard, input_fun)
        read_loop(parent, dashboard, input_fun)

      :eof ->
        send(parent, {:EXIT, self(), :normal})

      _other ->
        read_loop(parent, dashboard, input_fun)
    end
  end

  defp read_escape_sequence(dashboard, input_fun) do
    case {input_fun.(), input_fun.()} do
      {"[", "A"} -> StatusDashboard.select_previous(dashboard)
      {"[", "B"} -> StatusDashboard.select_next(dashboard)
      _ -> :ok
    end
  end

  defp enter_raw_mode(true), do: :ok

  defp enter_raw_mode(false) do
    with {:ok, device} <- tty_device() do
      run_stty(device, ["-icanon", "-echo", "-isig", "-ixon", "min", "1", "time", "0"])
    end
  end

  defp restore_terminal do
    with {:ok, device} <- tty_device() do
      _ = run_stty(device, ["sane"])
      :ok
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
