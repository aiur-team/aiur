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
  defp enter_raw_mode(false), do: run_stty("stty raw -echo")

  defp restore_terminal do
    _ = run_stty("stty sane")
    :ok
  end

  defp run_stty(command) do
    port = Port.open({:spawn, command}, [:exit_status, :nouse_stdio])

    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, status}} -> {:error, "#{command} exited with status #{status}"}
    after
      2_000 ->
        Port.close(port)
        {:error, "#{command} timed out"}
    end
  rescue
    error in ErlangError -> {:error, Exception.message(error)}
  end
end
