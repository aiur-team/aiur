defmodule Aiur.AgentList.Input do
  @moduledoc """
  Stdio owner for the agent-list pane.

  Reads bytes in raw mode, parses arrow keys via CSI escape sequences,
  and dispatches simple navigation/open events to a target GenServer
  (the `AgentList.App`).

  Accepts the same `:input_fun` and `:skip_raw_mode` test seams as the
  legacy `Aiur.TerminalInput`. Replaces that module for the
  new pane-based architecture.
  """

  use GenServer
  require Logger

  alias Aiur.AgentList.App
  alias Aiur.Os

  @type state :: %{reader_pid: pid(), target: GenServer.name(), restore?: boolean()}

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
    target = Keyword.get(opts, :target, App)
    input_fun = Keyword.get(opts, :input_fun, fn -> IO.binread(:stdio, 1) end)
    skip_raw_mode? = Keyword.get(opts, :skip_raw_mode, false)
    Process.flag(:trap_exit, true)

    case enter_raw_mode(skip_raw_mode?) do
      :ok ->
        Logger.info("AgentList.Input started in raw mode (target=#{inspect(target)})")
        parent = self()
        reader_pid = spawn_link(fn -> read_loop(parent, target, input_fun) end)
        {:ok, %{reader_pid: reader_pid, target: target, restore?: not skip_raw_mode?}}

      {:error, reason} ->
        Logger.warning("AgentList.Input disabled: #{inspect(reason)}")
        :ignore
    end
  end

  @impl true
  def terminate(_reason, %{restore?: true}) do
    restore_terminal()
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_info({:EXIT, pid, reason}, %{reader_pid: pid} = state) do
    if reason != :normal do
      Logger.warning("AgentList.Input reader exited: #{inspect(reason)}")
    end

    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp read_loop(parent, target, input_fun) do
    case input_fun.() do
      :eof ->
        :ok

      "" ->
        read_loop(parent, target, input_fun)

      byte ->
        dispatch(byte, target, input_fun)
        read_loop(parent, target, input_fun)
    end
  end

  defp dispatch("\e", target, input_fun) do
    case input_fun.() do
      "[" -> read_csi(target, input_fun, "")
      _ -> :ok
    end
  end

  defp dispatch("\r", target, _input_fun), do: App.activate(target)
  defp dispatch("\n", target, _input_fun), do: App.activate(target)
  defp dispatch(" ", target, _input_fun), do: App.toggle_pause(target)
  defp dispatch("k", target, _input_fun), do: App.select_previous(target)
  defp dispatch("j", target, _input_fun), do: App.select_next(target)
  defp dispatch("a", target, _input_fun), do: App.attach_selected(target)
  defp dispatch("r", target, _input_fun), do: App.toggle_remote_control(target)
  defp dispatch("v", target, _input_fun), do: App.toggle_layout_orientation(target)
  defp dispatch("?", target, _input_fun), do: App.toggle_help(target)
  defp dispatch("q", target, _input_fun), do: App.quit(target)
  # Capital-O is the fallback "open in new pane" keybind for terminals
  # that don't emit a distinct sequence for Shift+Enter. CSI-u-capable
  # terminals also reach activate_new_pane via the `\e[13;2u` parser
  # below.
  defp dispatch("O", target, _input_fun), do: App.activate_new_pane(target)
  defp dispatch(_byte, _target, _input_fun), do: :ok

  defp read_csi(target, input_fun, params) do
    case input_fun.() do
      :eof ->
        :ok

      byte ->
        if csi_final?(byte) do
          dispatch_csi(target, params, byte)
        else
          read_csi(target, input_fun, params <> byte)
        end
    end
  end

  defp csi_final?(<<c>>) when c in ?A..?Z or c in ?a..?z or c == ?~, do: true
  defp csi_final?(_byte), do: false

  defp dispatch_csi(target, "", "A"), do: App.select_previous(target)
  defp dispatch_csi(target, "", "B"), do: App.select_next(target)
  defp dispatch_csi(target, "", "C"), do: App.adjust_max_concurrent_agents(target, 1)
  defp dispatch_csi(target, "", "D"), do: App.adjust_max_concurrent_agents(target, -1)
  # CSI-u: Shift+Enter is `\e[13;2u` under modifyOtherKeys-2 / kitty
  # keyboard protocol. The second parameter (`2`) is the Shift modifier
  # bit. Plain Enter is `\e[13u`. Other shifted keys (e.g. `\e[97;2u`
  # for Shift+a) are ignored.
  defp dispatch_csi(target, "13;2", "u"), do: App.activate_new_pane(target)
  defp dispatch_csi(target, "13", "u"), do: App.activate(target)
  defp dispatch_csi(_target, _params, _final), do: :ok

  defp enter_raw_mode(true), do: :ok

  defp enter_raw_mode(false) do
    with :ok <- Os.stty(["-icanon", "-echo", "-isig", "-ixon", "min", "0", "time", "1"]) do
      # modifyOtherKeys=2 + kitty extended keys = terminal emits
      # `\e[13;2u` for Shift+Enter rather than collapsing it to plain
      # `\r`. Terminals that don't grok these sequences silently ignore
      # them, so the capital-O fallback in `dispatch/3` still works.
      IO.write("\e[>4;2m\e[?2017h")
      :ok
    end
  rescue
    _ -> {:error, :stty_unavailable}
  end

  defp restore_terminal do
    IO.write("\e[?2017l\e[>4;0m\e[?25h")
    Os.stty(["sane"])
  rescue
    _ -> :ok
  end
end
