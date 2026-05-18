defmodule Aiur.AgentList.App do
  @moduledoc """
  Agent-list pane orchestrator.

  Subscribes to `"agents:running"` and `"agents:status"` via
  `Aiur.AgentPubSub`, keeps the current list of agent summaries
  in state, dispatches selection/activation events from
  `Aiur.AgentList.Input`, and renders to stdout through
  `Aiur.AgentList.Renderer`.

  On activate (enter / space / `i`), calls
  `Aiur.PaneManager.open_conversation/3` with the configured
  command template (typically `bin/aiur conversation <id>`).

  Accepts these test seams:
    * `:write_fun` — function called with the rendered iodata (defaults to `IO.write/1`).
    * `:pane_manager` — name of the PaneManager GenServer.
    * `:command_template` — string with `~s` placeholder filled by the
      selected identifier. Defaults to `bin/aiur conversation`.
  """

  use GenServer
  require Logger

  alias Aiur.AgentList.Renderer
  alias Aiur.{AgentPubSub, Config, HttpServer, Orchestrator, PaneManager, Tracker}

  # `init/1` and `render/1` go through GenServer-side and IO callbacks
  # whose return shapes dialyzer can't fully trace; the warnings are
  # spurious false positives. Suppress at module scope.
  @dialyzer {:no_return, init: 1, render: 1}
  @dialyzer {:nowarn_function, render: 1}

  @refresh_tick_ms 1_000
  # Geometry-watch interval. Far faster than the refresh tick so that
  # tmux resizes (caused by another pane opening/closing in the same
  # window) reflow the agent list within a quarter-second — the old
  # 1-second cadence left visibly stale layout until the next refresh.
  @geometry_tick_ms 250

  @type state :: %{
          summaries: [map()],
          selection_index: non_neg_integer(),
          columns: pos_integer(),
          rows: pos_integer(),
          write_fun: (iodata() -> any()),
          pane_manager: GenServer.name(),
          command_template: String.t()
        }

  # Public API ----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec select_previous(GenServer.server()) :: :ok
  def select_previous(server \\ __MODULE__), do: GenServer.cast(server, :select_previous)

  @spec select_next(GenServer.server()) :: :ok
  def select_next(server \\ __MODULE__), do: GenServer.cast(server, :select_next)

  @spec activate(GenServer.server()) :: :ok
  def activate(server \\ __MODULE__), do: GenServer.cast(server, :activate)

  @spec quit(GenServer.server()) :: :ok
  def quit(server \\ __MODULE__), do: GenServer.cast(server, :quit)

  @spec toggle_help(GenServer.server()) :: :ok
  def toggle_help(server \\ __MODULE__), do: GenServer.cast(server, :toggle_help)

  @spec snapshot(GenServer.server()) :: state()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  # GenServer callbacks -------------------------------------------------------

  @impl true
  def init(opts) do
    write_fun = Keyword.get(opts, :write_fun, &IO.write/1)
    pane_manager = Keyword.get(opts, :pane_manager, PaneManager)
    command_template = Keyword.get(opts, :command_template, default_command_template())
    {cols, rows} = terminal_geometry()

    AgentPubSub.subscribe_running()
    AgentPubSub.subscribe_status()

    state = %{
      summaries: [],
      selection_index: 0,
      columns: cols,
      rows: rows,
      help_visible?: false,
      write_fun: write_fun,
      pane_manager: pane_manager,
      command_template: command_template
    }

    schedule_refresh_tick()
    schedule_geometry_tick()
    render(state)
    {:ok, state}
  end

  defp schedule_refresh_tick do
    Process.send_after(self(), :refresh_tick, @refresh_tick_ms)
  end

  defp schedule_geometry_tick do
    Process.send_after(self(), :geometry_tick, @geometry_tick_ms)
  end

  @impl true
  def handle_cast(:select_previous, state) do
    new_state = move_selection(state, -1)
    render(new_state)
    {:noreply, new_state}
  end

  def handle_cast(:select_next, state) do
    new_state = move_selection(state, 1)
    render(new_state)
    {:noreply, new_state}
  end

  def handle_cast(:activate, state) do
    case Enum.at(state.summaries, state.selection_index) do
      %{identifier: identifier} ->
        command = "#{state.command_template} #{identifier}"
        # Routes through the agent-native facade so external consumers
        # (MCP bridge, automation agents) drive conversations the same
        # way the CLI does.
        _ = PaneManager.open_conversation(state.pane_manager, identifier, command)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_cast(:quit, state) do
    {:stop, :normal, state}
  end

  def handle_cast(:toggle_help, state) do
    new_state = %{state | help_visible?: not Map.get(state, :help_visible?, false)}
    render(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info({:running_changed, summaries}, state) do
    new_state = clamp_selection(%{state | summaries: visible_summaries(summaries)})
    render(new_state)
    {:noreply, new_state}
  end

  def handle_info({:status_changed, _}, state), do: {:noreply, state}

  def handle_info({:alert, %{}}, state), do: {:noreply, state}

  def handle_info(:refresh_tick, state) do
    render(state)
    schedule_refresh_tick()
    {:noreply, state}
  end

  def handle_info(:geometry_tick, state) do
    # Re-render whenever the terminal geometry changes so a tmux pane
    # resize (caused by another pane being added/closed) reflows
    # immediately. No-op when nothing changed to avoid wasted writes.
    {cols, rows} = terminal_geometry()
    schedule_geometry_tick()

    if cols == state.columns and rows == state.rows do
      {:noreply, state}
    else
      new_state = %{state | columns: cols, rows: rows}
      render(new_state)
      {:noreply, new_state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Internals -----------------------------------------------------------------

  defp move_selection(state, delta) do
    count = length(state.summaries)
    new_index = if count == 0, do: 0, else: rem(state.selection_index + delta + count, count)
    %{state | selection_index: new_index}
  end

  defp clamp_selection(state) do
    count = length(state.summaries)

    cond do
      count == 0 -> %{state | selection_index: 0}
      state.selection_index >= count -> %{state | selection_index: count - 1}
      true -> state
    end
  end

  # Canonical "what's shown to the user" transform. Applied on intake so
  # state.summaries matches what the renderer draws — keeping the :activate
  # handler's Enum.at index aligned with the visible row.
  defp visible_summaries(summaries) do
    summaries
    |> Enum.reject(fn s ->
      tag = Map.get(s, :tag)
      tag in ["agent:cancelled", "agent:canceled", "agent:done"]
    end)
    |> Enum.sort_by(fn s ->
      bucket =
        case Map.get(s, :status) do
          :running -> 0
          :queued -> 1
          _ -> 2
        end

      {bucket, to_string(Map.get(s, :identifier) || "")}
    end)
  end

  defp render(state) do
    # Re-query geometry on every render: tmux resizes panes after splits and
    # doesn't update COLUMNS/LINES in our env, so the values captured at
    # init/1 go stale.
    {cols, rows} = terminal_geometry()

    render_state =
      state
      |> Map.take([:summaries, :selection_index, :help_visible?])
      |> Map.put(:columns, cols)
      |> Map.put(:rows, rows)
      |> Map.put(:project_label, project_label())
      |> Map.put(:dashboard_url, dashboard_url())
      |> Map.put(:refresh_label, refresh_label())
      |> Map.put(:agent_kind, agent_kind())
      |> Map.put(:agent_count, length(state.summaries))
      |> Map.put(:max_agents, max_agents())

    state.write_fun.(Renderer.render(render_state))
    :ok
  end

  defp project_label do
    case safe_call(fn -> Tracker.project_identity() end) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp dashboard_url do
    host = safe_call(fn -> Config.server_host() end)
    port = safe_call(fn -> HttpServer.bound_port() end) || safe_call(fn -> Config.server_port() end)

    cond do
      not is_integer(port) -> nil
      port <= 0 -> nil
      is_binary(host) and host != "" -> "http://#{host}:#{port}/"
      true -> "http://127.0.0.1:#{port}/"
    end
  end

  defp refresh_label do
    case safe_call(fn -> Orchestrator.poll_status() end) do
      %{checking?: true} ->
        # The "in-progress" state collapses to the same `0s` label as
        # the final-second countdown — they read the same to the
        # operator and the unified label is calmer to look at.
        "0s"

      %{next_poll_in_ms: ms} when is_integer(ms) ->
        seconds = div(max(ms, 0) + 999, 1000)
        "#{seconds}s"

      _ ->
        nil
    end
  end

  defp agent_kind do
    case safe_call(fn -> Config.agent_kind() end) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp max_agents do
    case safe_call(fn -> Config.max_concurrent_agents() end) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
    _, _ -> nil
  end

  defp terminal_geometry do
    cols =
      case :io.columns() do
        {:ok, c} when is_integer(c) and c > 0 -> c
        _ -> parse_int(System.get_env("COLUMNS"), 80)
      end

    rows =
      case :io.rows() do
        {:ok, r} when is_integer(r) and r > 0 -> r
        _ -> parse_int(System.get_env("LINES"), 24)
      end

    {cols, rows}
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp default_command_template do
    bin = System.get_env("AIUR_BIN") || "./bin/aiur"
    mise = System.get_env("AIUR_MISE_BIN")

    if is_binary(mise) and mise != "" do
      ~s(#{mise} exec -- #{bin} conversation)
    else
      "#{bin} conversation"
    end
  end
end
