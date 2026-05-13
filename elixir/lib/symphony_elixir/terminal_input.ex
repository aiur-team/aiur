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
        reader_pid = spawn_link(fn -> read_loop(parent, dashboard, input_fun, :list) end)
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

  defp read_loop(parent, dashboard, input_fun, mode) do
    case input_fun.() do
      :eof ->
        :ok

      "" ->
        read_loop(parent, dashboard, input_fun, mode)

      byte ->
        Logger.debug("TerminalInput received byte: #{inspect(byte)}")
        dispatch_byte(byte, parent, dashboard, input_fun, mode)
    end
  end

  defp dispatch_byte("\e", parent, dashboard, input_fun, {:text, _} = mode) do
    case input_fun.() do
      :eof -> handle_escape_timeout(parent, dashboard, input_fun, mode, :stop_reader)
      "" -> handle_escape_timeout(parent, dashboard, input_fun, mode, :continue)
      "[" -> handle_csi_escape(parent, dashboard, input_fun, mode)
      byte when byte in ["\r", "\n"] -> handle_alt_enter(parent, dashboard, input_fun)
      other -> handle_escape_other(other, parent, dashboard, input_fun, mode)
    end
  end

  defp dispatch_byte("\e", parent, dashboard, input_fun, mode) do
    case input_fun.() do
      :eof -> handle_escape_timeout(parent, dashboard, input_fun, mode, :stop_reader)
      "" -> handle_escape_timeout(parent, dashboard, input_fun, mode, :continue)
      "[" -> handle_csi_escape(parent, dashboard, input_fun, mode)
      other -> handle_escape_other(other, parent, dashboard, input_fun, mode)
    end
  end

  defp dispatch_byte(<<3>>, parent, dashboard, input_fun, {:text, :armed}) do
    StatusDashboard.close_log(dashboard)
    read_loop(parent, dashboard, input_fun, :list)
  end

  defp dispatch_byte(<<3>>, parent, dashboard, input_fun, {:text, :clear}) do
    StatusDashboard.pause_agent(dashboard)
    read_loop(parent, dashboard, input_fun, {:text, :armed})
  end

  defp dispatch_byte(<<3>>, parent, dashboard, input_fun, :log_nav) do
    StatusDashboard.close_log(dashboard)
    read_loop(parent, dashboard, input_fun, :list)
  end

  defp dispatch_byte(<<3>>, _parent, _dashboard, _input_fun, :list), do: System.stop(0)

  defp dispatch_byte("q", _parent, _dashboard, _input_fun, :list), do: System.stop(0)

  defp dispatch_byte("i", parent, dashboard, input_fun, :list) do
    StatusDashboard.open_log(dashboard)
    read_loop(parent, dashboard, input_fun, {:text, :clear})
  end

  defp dispatch_byte(byte, parent, dashboard, input_fun, :list) when byte in [" ", "\r", "\n"] do
    StatusDashboard.open_log(dashboard)
    read_loop(parent, dashboard, input_fun, {:text, :clear})
  end

  defp dispatch_byte("\t", parent, dashboard, input_fun, {:text, _pause_state}) do
    StatusDashboard.exit_typing(dashboard)
    read_loop(parent, dashboard, input_fun, :log_nav)
  end

  defp dispatch_byte("\t", parent, dashboard, input_fun, :log_nav) do
    StatusDashboard.enter_typing(dashboard)
    read_loop(parent, dashboard, input_fun, {:text, :clear})
  end

  defp dispatch_byte("j", parent, dashboard, input_fun, mode) when mode in [:list, :log_nav] do
    StatusDashboard.select_next(dashboard)
    read_loop(parent, dashboard, input_fun, mode)
  end

  defp dispatch_byte("k", parent, dashboard, input_fun, mode) when mode in [:list, :log_nav] do
    StatusDashboard.select_previous(dashboard)
    read_loop(parent, dashboard, input_fun, mode)
  end

  defp dispatch_byte(" ", parent, dashboard, input_fun, :log_nav) do
    StatusDashboard.open_log(dashboard)
    read_loop(parent, dashboard, input_fun, {:text, :clear})
  end

  defp dispatch_byte("\e", parent, dashboard, input_fun, :log_nav) do
    StatusDashboard.close_log(dashboard)
    read_loop(parent, dashboard, input_fun, :list)
  end

  defp dispatch_byte(byte, parent, dashboard, input_fun, {:text, _pause_state}) when byte in ["\r", "\n"] do
    StatusDashboard.submit_message(dashboard)
    read_loop(parent, dashboard, input_fun, {:text, :clear})
  end

  defp dispatch_byte(byte, parent, dashboard, input_fun, {:text, _pause_state}) when byte in [<<8>>, <<127>>] do
    StatusDashboard.backspace(dashboard)
    read_loop(parent, dashboard, input_fun, {:text, :clear})
  end

  defp dispatch_byte(byte, parent, dashboard, input_fun, {:text, _pause_state}) do
    if printable?(byte), do: StatusDashboard.append_text(dashboard, byte)
    read_loop(parent, dashboard, input_fun, {:text, :clear})
  end

  defp dispatch_byte(_other, parent, dashboard, input_fun, mode) do
    read_loop(parent, dashboard, input_fun, mode)
  end

  defp handle_escape_timeout(_parent, dashboard, _input_fun, {:text, :armed}, :stop_reader) do
    StatusDashboard.close_log(dashboard)
    :ok
  end

  defp handle_escape_timeout(parent, dashboard, input_fun, {:text, :armed}, :continue) do
    StatusDashboard.close_log(dashboard)
    read_loop(parent, dashboard, input_fun, :list)
  end

  defp handle_escape_timeout(_parent, dashboard, _input_fun, {:text, :clear}, :stop_reader) do
    StatusDashboard.pause_agent(dashboard)
    :ok
  end

  defp handle_escape_timeout(parent, dashboard, input_fun, {:text, :clear}, :continue) do
    StatusDashboard.pause_agent(dashboard)
    read_loop(parent, dashboard, input_fun, {:text, :armed})
  end

  defp handle_escape_timeout(parent, dashboard, input_fun, :log_nav, :continue) do
    StatusDashboard.close_log(dashboard)
    read_loop(parent, dashboard, input_fun, :list)
  end

  defp handle_escape_timeout(_parent, dashboard, _input_fun, :log_nav, :stop_reader) do
    StatusDashboard.close_log(dashboard)
    :ok
  end
  defp handle_escape_timeout(_parent, _dashboard, _input_fun, :list, _action), do: System.stop(0)

  defp handle_csi_escape(parent, dashboard, input_fun, mode) do
    case read_csi(dashboard, input_fun, "", mode) do
      :paste_start ->
        pasted = consume_until_paste_end(input_fun)
        append_paste(dashboard, pasted, mode)
        read_loop(parent, dashboard, input_fun, mode)

      new_mode ->
        read_loop(parent, dashboard, input_fun, new_mode)
    end
  end

  defp handle_alt_enter(parent, dashboard, input_fun) do
    StatusDashboard.append_text(dashboard, "\n")
    read_loop(parent, dashboard, input_fun, {:text, :clear})
  end

  defp handle_escape_other(other, parent, dashboard, input_fun, {:text, :armed}) do
    StatusDashboard.close_log(dashboard)
    dispatch_byte(other, parent, dashboard, input_fun, :list)
  end

  defp handle_escape_other(other, parent, dashboard, input_fun, {:text, :clear}) do
    StatusDashboard.pause_agent(dashboard)
    dispatch_byte(other, parent, dashboard, input_fun, {:text, :armed})
  end

  defp handle_escape_other(other, parent, dashboard, input_fun, mode) do
    dispatch_byte(other, parent, dashboard, input_fun, mode)
  end

  defp append_paste(dashboard, pasted, {:text, _pause_state}), do: StatusDashboard.append_text(dashboard, pasted)
  defp append_paste(_dashboard, _pasted, _mode), do: :ok

  defp read_csi(dashboard, input_fun, params, mode) do
    case input_fun.() do
      :eof ->
        mode

      byte ->
        if csi_final?(byte) do
          dispatch_csi(dashboard, params, byte, mode)
        else
          read_csi(dashboard, input_fun, params <> byte, mode)
        end
    end
  end

  defp csi_final?(<<c>>) when c in ?A..?Z or c in ?a..?z or c == ?~, do: true
  defp csi_final?(_), do: false

  defp dispatch_csi(dashboard, "", "A", mode) when mode in [:list, :log_nav],
    do: tap(mode, fn _ -> StatusDashboard.select_previous(dashboard) end)

  defp dispatch_csi(dashboard, "", "B", mode) when mode in [:list, :log_nav],
    do: tap(mode, fn _ -> StatusDashboard.select_next(dashboard) end)

  defp dispatch_csi(dashboard, "", "D", :log_nav), do: tap(:list, fn _ -> StatusDashboard.close_log(dashboard) end)
  defp dispatch_csi(dashboard, "5", "~", :log_nav), do: tap(:log_nav, fn _ -> StatusDashboard.scroll_log_up(dashboard) end)
  defp dispatch_csi(dashboard, "6", "~", :log_nav), do: tap(:log_nav, fn _ -> StatusDashboard.scroll_log_down(dashboard) end)
  defp dispatch_csi(_dashboard, "200", "~", _mode), do: :paste_start
  defp dispatch_csi(_dashboard, "201", "~", mode), do: mode
  defp dispatch_csi(_dashboard, _params, _final, mode), do: mode

  defp consume_until_paste_end(input_fun, acc \\ "", last_six \\ "") do
    case input_fun.() do
      :eof ->
        acc

      byte ->
        joined = last_six <> byte
        window = if String.length(joined) > 6, do: String.slice(joined, -6, 6), else: joined

        if window == "\e[201~" do
          String.replace_suffix(acc <> byte, "\e[201~", "")
        else
          consume_until_paste_end(input_fun, acc <> byte, window)
        end
    end
  end

  defp printable?(<<c>>) when c >= 32 and c != 127, do: true
  defp printable?(_byte), do: false

  defp enter_raw_mode(true), do: :ok

  defp enter_raw_mode(false) do
    with :ok <-
           SymphonyElixir.Os.stty([
             "-icanon",
             "-echo",
             "-isig",
             "-ixon",
             "min",
             "0",
             "time",
             "1"
           ]) do
      enable_bracketed_paste()
      :ok
    end
  end

  defp restore_terminal do
    disable_bracketed_paste()
    SymphonyElixir.Os.stty(["sane"])
    :ok
  end

  defp enable_bracketed_paste, do: IO.write("\e[?2004h")
  defp disable_bracketed_paste, do: IO.write("\e[?2004l")
end
