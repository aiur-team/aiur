defmodule SymphonyElixir.StatusDashboard do
  @moduledoc """
  Renders a status snapshot for orchestrator and worker activity as a terminal UI.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{AgentChat, AgentLog, Config, HttpServer, Tracker}
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.ObservabilityPubSub

  @minimum_idle_rerender_ms 1_000
  @throughput_window_ms 5_000
  @throughput_graph_window_ms 10 * 60 * 1000
  @throughput_graph_columns 24
  @sparkline_blocks ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
  @running_id_width 6
  @running_tag_width 8
  @running_state_width 10
  @running_issue_width 22
  @running_age_width 12
  @default_terminal_columns 115
  @default_terminal_rows 40
  @min_log_pane_lines 3
  @log_pane_chrome_width 8

  @ansi_reset IO.ANSI.reset()
  @ansi_bold IO.ANSI.bright()
  @ansi_cyan IO.ANSI.cyan()
  @ansi_dim IO.ANSI.faint()
  @ansi_green IO.ANSI.green()
  @ansi_red IO.ANSI.red()
  @ansi_orange IO.ANSI.yellow()
  @ansi_yellow IO.ANSI.yellow()
  @ansi_magenta IO.ANSI.magenta()
  @ansi_gray IO.ANSI.light_black()
  @ansi_white IO.ANSI.light_white()
  @ansi_light_cyan IO.ANSI.light_cyan()
  @ansi_light_green IO.ANSI.light_green()
  @ansi_light_magenta IO.ANSI.light_magenta()
  @ansi_input_dark_bg "\e[48;5;236m"
  @ansi_input_light_bg "\e[48;5;252m"
  @ansi_input_dark_fg "\e[38;5;255m"
  @ansi_input_light_fg "\e[38;5;235m"
  @ansi_input_help_dark "\e[38;5;248m"
  @ansi_input_help_light "\e[38;5;245m"

  defstruct [
    :refresh_ms,
    :enabled,
    :render_interval_ms,
    :refresh_ms_override,
    :enabled_override,
    :render_interval_ms_override,
    :render_fun,
    :token_samples,
    :last_tps_second,
    :last_tps_value,
    :last_rendered_content,
    :last_rendered_at_ms,
    :pending_content,
    :flush_timer_ref,
    :last_snapshot_fingerprint,
    :last_snapshot_data,
    :selected_index,
    :view
  ]

  @type log_view :: %{
          issue_identifier: String.t(),
          workspace_path: String.t() | nil,
          title: String.t() | nil,
          scroll: non_neg_integer(),
          last_total_lines: non_neg_integer(),
          mode: :browsing | :typing,
          composer: map()
        }

  @type view :: :list | {:log, log_view()}

  @type t :: %__MODULE__{
          refresh_ms: pos_integer(),
          enabled: boolean(),
          render_interval_ms: pos_integer(),
          refresh_ms_override: pos_integer() | nil,
          enabled_override: boolean() | nil,
          render_interval_ms_override: pos_integer() | nil,
          render_fun: (String.t() -> term()) | (String.t(), {pos_integer(), pos_integer()} | nil -> term()),
          token_samples: [{integer(), integer()}],
          last_tps_second: integer() | nil,
          last_tps_value: float() | nil,
          last_rendered_content: String.t() | nil,
          last_rendered_at_ms: integer() | nil,
          pending_content: String.t() | {String.t(), {pos_integer(), pos_integer()} | nil} | nil,
          flush_timer_ref: reference() | nil,
          last_snapshot_fingerprint: term() | nil,
          last_snapshot_data: term() | nil,
          selected_index: non_neg_integer() | nil,
          view: view()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec notify_update(GenServer.name()) :: :ok
  def notify_update(server \\ __MODULE__) do
    ObservabilityPubSub.broadcast_update()

    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        send(pid, :refresh)
        :ok

      _ ->
        :ok
    end
  end

  @impl true
  def init(opts) do
    refresh_ms_override = keyword_override(opts, :refresh_ms)
    enabled_override = keyword_override(opts, :enabled)
    render_interval_ms_override = keyword_override(opts, :render_interval_ms)
    refresh_ms = refresh_ms_override || Config.observability_refresh_ms()
    render_interval_ms = render_interval_ms_override || Config.observability_render_interval_ms()
    render_fun = Keyword.get(opts, :render_fun, &render_to_terminal/2)
    enabled = resolve_override(enabled_override, Config.observability_enabled?() and dashboard_enabled?())
    schedule_tick(refresh_ms, enabled)

    {:ok,
     %__MODULE__{
       refresh_ms: refresh_ms,
       enabled: enabled,
       render_interval_ms: render_interval_ms,
       refresh_ms_override: refresh_ms_override,
       enabled_override: enabled_override,
       render_interval_ms_override: render_interval_ms_override,
       render_fun: render_fun,
       token_samples: [],
       last_tps_second: nil,
       last_tps_value: nil,
       last_rendered_content: nil,
       last_rendered_at_ms: nil,
       pending_content: nil,
       flush_timer_ref: nil,
       last_snapshot_fingerprint: nil,
       last_snapshot_data: nil,
       selected_index: Keyword.get(opts, :selected_index),
       view: :list
     }}
  end

  @spec select_next(GenServer.name()) :: :ok
  def select_next(server \\ __MODULE__), do: GenServer.cast(server, {:select_agent, 1})

  @spec select_previous(GenServer.name()) :: :ok
  def select_previous(server \\ __MODULE__), do: GenServer.cast(server, {:select_agent, -1})

  @spec open_log(GenServer.name()) :: :ok
  def open_log(server \\ __MODULE__), do: GenServer.cast(server, :open_log)

  @spec close_log(GenServer.name()) :: :ok
  def close_log(server \\ __MODULE__), do: GenServer.cast(server, :close_log)

  @spec scroll_log_up(GenServer.name()) :: :ok
  def scroll_log_up(server \\ __MODULE__), do: GenServer.cast(server, {:scroll_log, :up})

  @spec scroll_log_down(GenServer.name()) :: :ok
  def scroll_log_down(server \\ __MODULE__), do: GenServer.cast(server, {:scroll_log, :down})

  @spec enter_typing(GenServer.name()) :: :ok
  def enter_typing(server \\ __MODULE__), do: GenServer.cast(server, :enter_typing)

  @spec exit_typing(GenServer.name()) :: :ok
  def exit_typing(server \\ __MODULE__), do: GenServer.cast(server, :exit_typing)

  @spec append_text(GenServer.name(), String.t()) :: :ok
  def append_text(server \\ __MODULE__, text), do: GenServer.cast(server, {:append_text, text})

  @spec backspace(GenServer.name()) :: :ok
  def backspace(server \\ __MODULE__), do: GenServer.cast(server, :backspace)

  @spec move_cursor_left(GenServer.name()) :: :ok
  def move_cursor_left(server \\ __MODULE__), do: GenServer.cast(server, :move_cursor_left)

  @spec move_cursor_right(GenServer.name()) :: :ok
  def move_cursor_right(server \\ __MODULE__), do: GenServer.cast(server, :move_cursor_right)

  @spec submit_message(GenServer.name()) :: :ok
  def submit_message(server \\ __MODULE__), do: GenServer.cast(server, :submit_message)

  @spec pause_agent(GenServer.name()) :: :ok
  def pause_agent(server \\ __MODULE__), do: GenServer.cast(server, :pause_agent)

  @spec render_offline_status() :: :ok
  def render_offline_status do
    content =
      [
        colorize("╭─ SYMPHONY STATUS", @ansi_bold),
        colorize("│ app_status=offline", @ansi_red),
        closing_border()
      ]
      |> Enum.join("\n")

    render_to_terminal(content, nil)
    :ok
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed rendering offline status: #{Exception.message(error)}")
      :ok
  end

  @impl true
  def handle_info(:tick, %{enabled: true} = state) do
    state = refresh_runtime_config(state)
    state = maybe_render(state)
    schedule_tick(state.refresh_ms, true)
    {:noreply, state}
  end

  def handle_info(:refresh, %{enabled: true} = state), do: {:noreply, maybe_render(refresh_runtime_config(state))}
  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info({:flush_render, timer_ref}, %{enabled: true, flush_timer_ref: timer_ref} = state) do
    now_ms = System.monotonic_time(:millisecond)

    state =
      case state.pending_content do
        nil ->
          %{state | flush_timer_ref: nil}

        {content, cursor_position} ->
          state
          |> Map.put(:flush_timer_ref, nil)
          |> Map.put(:pending_content, nil)
          |> render_content(content, cursor_position, now_ms)
      end

    {:noreply, state}
  end

  def handle_info({:flush_render, _timer_ref}, state), do: {:noreply, state}
  def handle_info(:tick, state), do: {:noreply, state}

  @impl true
  def handle_cast({:select_agent, direction}, %{enabled: true} = state) when direction in [-1, 1] do
    snapshot_data = snapshot_data()
    new_index = move_selected_index(state.selected_index, snapshot_data, direction)

    state =
      state
      |> Map.put(:selected_index, new_index)
      |> retarget_log_view(snapshot_data, new_index)
      |> Map.put(:last_snapshot_fingerprint, nil)
      |> maybe_render()

    {:noreply, state}
  end

  def handle_cast({:select_agent, _direction}, state), do: {:noreply, state}

  def handle_cast(:open_log, %{enabled: true, view: :list} = state) do
    snapshot_data = snapshot_data()

    case running_entry_at(snapshot_data, state.selected_index) do
      nil ->
        Logger.debug("open_log: no running entry at selected_index=#{inspect(state.selected_index)}")
        {:noreply, state}

      entry ->
        Logger.debug("open_log: opening pane for #{inspect(entry.identifier)}")

        state =
          state
          |> Map.put(:view, build_log_view(entry))
          |> Map.put(:last_snapshot_fingerprint, nil)
          |> maybe_render()

        {:noreply, state}
    end
  end

  def handle_cast(:open_log, %{enabled: true, view: {:log, _log_view}} = state) do
    snapshot_data = snapshot_data()

    case running_entry_at(snapshot_data, state.selected_index) do
      nil ->
        {:noreply, state}

      entry ->
        state =
          state
          |> Map.put(:view, build_log_view(entry))
          |> Map.put(:last_snapshot_fingerprint, nil)
          |> maybe_render()

        {:noreply, state}
    end
  end

  def handle_cast(:open_log, state) do
    Logger.debug("open_log: no-op fallthrough (enabled=#{inspect(state.enabled)}, view=#{inspect(state.view)})")
    {:noreply, state}
  end

  def handle_cast(:close_log, %{enabled: true, view: {:log, _}} = state) do
    state =
      state
      |> Map.put(:view, :list)
      |> Map.put(:last_snapshot_fingerprint, nil)
      |> maybe_render()

    {:noreply, state}
  end

  def handle_cast(:close_log, state), do: {:noreply, state}

  def handle_cast({:scroll_log, direction}, %{enabled: true, view: {:log, log_view}} = state)
      when direction in [:up, :down] do
    new_scroll = clamped_scroll(log_view, direction)

    state =
      state
      |> Map.put(:view, {:log, %{log_view | scroll: new_scroll}})
      |> Map.put(:last_snapshot_fingerprint, nil)
      |> maybe_render()

    {:noreply, state}
  end

  def handle_cast({:scroll_log, _direction}, state), do: {:noreply, state}

  def handle_cast(:enter_typing, %{enabled: true, view: {:log, log_view}} = state) do
    {:noreply, state |> update_log_view(%{log_view | mode: :typing}) |> maybe_render()}
  end

  def handle_cast(:enter_typing, state), do: {:noreply, state}

  def handle_cast(:exit_typing, %{enabled: true, view: {:log, log_view}} = state) do
    {:noreply, state |> update_log_view(%{log_view | mode: :browsing}) |> maybe_render()}
  end

  def handle_cast(:exit_typing, state), do: {:noreply, state}

  def handle_cast({:append_text, text}, %{enabled: true, view: {:log, %{mode: :typing} = log_view}} = state)
      when is_binary(text) do
    composer = insert_text_at_cursor(log_view.composer, text)

    state =
      state
      |> update_log_view(%{log_view | composer: %{composer | last_error: nil}})
      |> render_cached_interactive_frame()

    {:noreply, state}
  end

  def handle_cast({:append_text, _text}, state), do: {:noreply, state}

  def handle_cast(:backspace, %{enabled: true, view: {:log, %{mode: :typing} = log_view}} = state) do
    composer = backspace_at_cursor(log_view.composer)

    state =
      state
      |> update_log_view(%{log_view | composer: %{composer | last_error: nil}})
      |> render_cached_interactive_frame()

    {:noreply, state}
  end

  def handle_cast(:backspace, state), do: {:noreply, state}

  def handle_cast(:move_cursor_left, %{enabled: true, view: {:log, %{mode: :typing} = log_view}} = state) do
    composer = move_cursor(log_view.composer, -1)
    {:noreply, state |> update_log_view(%{log_view | composer: composer}) |> render_cached_interactive_frame()}
  end

  def handle_cast(:move_cursor_left, state), do: {:noreply, state}

  def handle_cast(:move_cursor_right, %{enabled: true, view: {:log, %{mode: :typing} = log_view}} = state) do
    composer = move_cursor(log_view.composer, 1)
    {:noreply, state |> update_log_view(%{log_view | composer: composer}) |> render_cached_interactive_frame()}
  end

  def handle_cast(:move_cursor_right, state), do: {:noreply, state}

  def handle_cast(:submit_message, %{enabled: true, view: {:log, %{mode: :typing} = log_view}} = state) do
    text = String.trim(log_view.composer.buffer)

    state =
      if text == "" do
        state
      else
        composer = submit_composer_text(log_view.issue_identifier, text, log_view.composer)

        update_log_view(state, %{log_view | composer: composer})
      end

    if text == "" do
      {:noreply, state}
    else
      {:noreply, render_cached_interactive_frame(%{state | last_snapshot_fingerprint: nil})}
    end
  end

  def handle_cast(:submit_message, state), do: {:noreply, state}

  def handle_cast(:pause_agent, %{enabled: true, view: {:log, log_view}} = state) do
    composer =
      case AgentChat.pause(log_view.issue_identifier) do
        {:ok, request_id} -> %{log_view.composer | pending_request_id: request_id, last_error: nil}
        {:error, reason} -> %{log_view.composer | last_error: format_operator_error(reason)}
      end

    {:noreply, state |> update_log_view(%{log_view | composer: composer}) |> maybe_render()}
  end

  def handle_cast(:pause_agent, state), do: {:noreply, state}

  defp submit_composer_text(issue_identifier, text, composer) do
    send_composer_message(fn -> AgentChat.send(issue_identifier, text) end, composer)
  end

  defp send_composer_message(send_fun, composer) when is_function(send_fun, 0) do
    case send_fun.() do
      {:ok, request_id} ->
        pending_message = %{id: request_id, text: composer.buffer, status: :pending}
        %{fresh_composer() | pending_request_id: request_id, local_pending_messages: [pending_message]}

      {:error, reason} ->
        %{composer | last_error: format_operator_error(reason)}
    end
  end

  defp refresh_runtime_config(%__MODULE__{} = state) do
    %{
      state
      | enabled: resolve_override(state.enabled_override, Config.observability_enabled?() and dashboard_enabled?()),
        refresh_ms: state.refresh_ms_override || Config.observability_refresh_ms(),
        render_interval_ms: state.render_interval_ms_override || Config.observability_render_interval_ms()
    }
  end

  defp schedule_tick(refresh_ms, true), do: Process.send_after(self(), :tick, refresh_ms)
  defp schedule_tick(_refresh_ms, false), do: :ok

  defp maybe_render(state) do
    now_ms = System.monotonic_time(:millisecond)
    {snapshot_data, token_samples} = snapshot_with_samples(state.token_samples, now_ms)
    previous_snapshot_data = state.last_snapshot_data

    render_snapshot_data =
      renderable_snapshot_data(snapshot_data, previous_snapshot_data, state.view)

    state =
      state
      |> Map.put(:token_samples, token_samples)
      |> reconcile_log_view_with_snapshot(snapshot_data)
      |> maybe_cache_snapshot_data(render_snapshot_data)

    current_tokens = snapshot_total_tokens(render_snapshot_data)

    {tps_second, tps} =
      throttled_tps(
        state.last_tps_second,
        state.last_tps_value,
        now_ms,
        token_samples,
        current_tokens
      )

    state =
      state
      |> Map.put(:last_tps_second, tps_second)
      |> Map.put(:last_tps_value, tps)

    snapshot_fingerprint = {render_snapshot_data, state.selected_index, state.view}

    if snapshot_fingerprint != state.last_snapshot_fingerprint or periodic_rerender_due?(state, now_ms) do
      {content, log_total_lines, cursor_position} =
        format_snapshot_content(
          render_snapshot_data,
          tps,
          selected_index: state.selected_index,
          view: state.view
        )

      state
      |> update_log_view_total_lines(log_total_lines)
      |> maybe_update_snapshot_fingerprint(snapshot_fingerprint)
      |> maybe_enqueue_render(content, cursor_position, now_ms)
    else
      state
    end
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed rendering status dashboard: #{Exception.message(error)}")
      state
  end

  defp maybe_enqueue_render(state, content, cursor_position, now_ms) do
    cond do
      content == state.last_rendered_content ->
        state

      render_now?(state, now_ms) ->
        render_content(state, content, cursor_position, now_ms)

      true ->
        schedule_flush_render(%{state | pending_content: {content, cursor_position}}, now_ms)
    end
  end

  defp maybe_update_snapshot_fingerprint(state, snapshot_data) do
    if snapshot_data == state.last_snapshot_fingerprint do
      state
    else
      Map.put(state, :last_snapshot_fingerprint, snapshot_data)
    end
  end

  defp periodic_rerender_due?(%{last_rendered_at_ms: nil}, _now_ms), do: true

  defp periodic_rerender_due?(%{last_rendered_at_ms: last_rendered_at_ms}, now_ms)
       when is_integer(last_rendered_at_ms) do
    now_ms - last_rendered_at_ms >= @minimum_idle_rerender_ms
  end

  defp periodic_rerender_due?(_state, _now_ms), do: false

  defp render_now?(%{last_rendered_at_ms: nil, flush_timer_ref: nil}, _now_ms), do: true

  defp render_now?(%{last_rendered_at_ms: last_rendered_at_ms, render_interval_ms: render_interval_ms}, now_ms)
       when is_integer(last_rendered_at_ms) and is_integer(render_interval_ms) do
    now_ms - last_rendered_at_ms >= render_interval_ms
  end

  defp render_now?(_state, _now_ms), do: false

  defp schedule_flush_render(%{flush_timer_ref: timer_ref} = state, _now_ms) when is_reference(timer_ref),
    do: state

  defp schedule_flush_render(state, now_ms) do
    delay_ms = flush_delay_ms(state, now_ms)
    timer_ref = make_ref()
    Process.send_after(self(), {:flush_render, timer_ref}, delay_ms)
    %{state | flush_timer_ref: timer_ref}
  end

  defp flush_delay_ms(%{last_rendered_at_ms: nil}, _now_ms), do: 1

  defp flush_delay_ms(
         %{last_rendered_at_ms: last_rendered_at_ms, render_interval_ms: render_interval_ms},
         now_ms
       ) do
    remaining = render_interval_ms - (now_ms - last_rendered_at_ms)
    max(1, remaining)
  end

  defp render_content(state, content, cursor_position, now_ms) do
    call_render_fun(state.render_fun, content, cursor_position)

    %{
      state
      | last_rendered_content: content,
        last_rendered_at_ms: now_ms,
        pending_content: nil,
        flush_timer_ref: nil
    }
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed rendering terminal dashboard frame: #{Exception.message(error)}")
      %{state | pending_content: nil, flush_timer_ref: nil}
  end

  defp call_render_fun(render_fun, content, cursor_position) when is_function(render_fun, 2),
    do: render_fun.(content, cursor_position)

  defp call_render_fun(render_fun, content, _cursor_position) when is_function(render_fun, 1),
    do: render_fun.(content)

  defp render_cached_interactive_frame(%{last_snapshot_data: nil} = state), do: maybe_render(state)

  defp render_cached_interactive_frame(%{last_snapshot_data: snapshot_data} = state) do
    now_ms = System.monotonic_time(:millisecond)

    {content, log_total_lines, cursor_position} =
      format_snapshot_content(
        snapshot_data,
        state.last_tps_value || 0.0,
        selected_index: state.selected_index,
        view: state.view
      )

    state
    |> update_log_view_total_lines(log_total_lines)
    |> render_content(content, cursor_position, now_ms)
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed rendering cached terminal dashboard frame: #{Exception.message(error)}")
      maybe_render(state)
  end

  defp maybe_cache_snapshot_data(state, {:ok, _snapshot} = snapshot_data),
    do: Map.put(state, :last_snapshot_data, snapshot_data)

  defp maybe_cache_snapshot_data(state, _snapshot_data), do: state

  defp renderable_snapshot_data(:error, {:ok, _snapshot} = last_snapshot_data, _view), do: last_snapshot_data

  defp renderable_snapshot_data(
         {:ok, %{running: running}} = snapshot_data,
         {:ok, %{running: previous_running}} = last_snapshot_data,
         {:log, log_view}
       )
       when is_list(running) and is_list(previous_running) do
    if preserve_previous_running_snapshot?(running, previous_running, log_view) do
      last_snapshot_data
    else
      snapshot_data
    end
  end

  defp renderable_snapshot_data(snapshot_data, _last_snapshot_data, _view), do: snapshot_data

  defp snapshot_with_samples(token_samples, now_ms) do
    case snapshot_data() do
      {:ok, %{agent_totals: agent_totals} = snapshot} ->
        total_tokens = Map.get(agent_totals, :total_tokens, 0)

        {{:ok, snapshot}, update_token_samples(token_samples, now_ms, total_tokens)}

      :error ->
        {
          :error,
          prune_samples(token_samples, now_ms)
        }
    end
  end

  defp snapshot_data do
    case snapshot_payload() do
      {:ok, %{running: running, retrying: retrying, agent_totals: agent_totals} = snapshot} ->
        {:ok,
         %{
           running: running,
           retrying: retrying,
           agent_totals: agent_totals,
           rate_limits: Map.get(snapshot, :rate_limits),
           polling: Map.get(snapshot, :polling)
         }}

      :error ->
        :error
    end
  end

  defp format_snapshot_content(snapshot_data, tps, opts) do
    terminal_columns_override = Keyword.get(opts, :terminal_columns)
    terminal_rows_override = Keyword.get(opts, :terminal_rows)
    selected_index = Keyword.get(opts, :selected_index)
    view = Keyword.get(opts, :view, :list)
    resolved_columns = terminal_columns_override || terminal_columns()
    resolved_rows = terminal_rows_override || terminal_rows()

    case snapshot_data do
      {:ok, %{running: running, retrying: retrying, agent_totals: agent_totals} = snapshot} ->
        rate_limits = Map.get(snapshot, :rate_limits)
        polling = Map.get(snapshot, :polling)
        agent_seconds_running = dashboard_runtime_seconds(running, agent_totals)
        agent_count = length(running)
        max_agents = Config.max_concurrent_agents()
        running_rows = format_running_rows(running, selected_index)

        two_pane_rows =
          format_two_pane_header(
            agent_count,
            max_agents,
            agent_seconds_running,
            rate_limits,
            polling,
            resolved_columns
          )

        header_lines =
          two_pane_rows ++
            [
              running_header_row(),
              "│",
              running_table_header_row(),
              running_table_separator_row()
            ] ++ running_rows

        {tail_lines, log_total_lines, cursor_position} =
          format_view_tail(view, header_lines, running, retrying, resolved_columns, resolved_rows)

        content =
          (header_lines ++ tail_lines)
          |> List.flatten()
          |> Enum.join("\n")

        {content, log_total_lines, cursor_position}

      :error ->
        content =
          [
            format_title_row(resolved_columns),
            colorize("│ Orchestrator snapshot unavailable", @ansi_red),
            colorize("│ Throughput: ", @ansi_bold) <> colorize("#{format_tps(tps)} tps", @ansi_cyan),
            format_project_link_lines(),
            format_project_refresh_line(nil),
            closing_border()
          ]
          |> List.flatten()
          |> Enum.join("\n")

        {content, nil, nil}
    end
  end

  defp format_view_tail(:list, _header_lines, running, retrying, _columns, _rows) do
    tail =
      if retrying == [] do
        [closing_border()]
      else
        running_to_backoff_spacer = if(running == [], do: [], else: ["│"])
        backoff_rows = format_retry_rows(retrying)

        running_to_backoff_spacer ++
          [colorize("├─ Backoff queue", @ansi_bold), "│"] ++
          backoff_rows ++
          [closing_border()]
      end

    {tail, nil, nil}
  end

  defp format_view_tail({:log, log_view}, header_lines, running, retrying, columns, rows) do
    messages = read_log_messages(log_view)
    display_log_view = reconcile_log_view_with_logged_operator_messages(log_view, running, messages)
    {log_lines, total_lines} = log_message_lines(messages, columns)

    metadata_lines = format_log_metadata(display_log_view, running, columns)
    queued_lines = format_queued_message_lines(display_log_view, running, columns, messages)
    header_height = length(List.flatten(header_lines))
    {input_section_lines, input_cursor} = format_input_section(display_log_view, columns)
    queued_chrome_lines = if(queued_lines == [], do: 0, else: length(queued_lines) + 1)
    chrome_lines = 1 + length(metadata_lines) + queued_chrome_lines + 1 + length(input_section_lines)
    # chrome: pane header + metadata + queued section + closing border + input section

    pane_budget = rows - header_height - chrome_lines - 1

    if pane_budget < @min_log_pane_lines do
      # Graceful degrade — too small to render a useful pane; fall back to list tail.
      format_view_tail(:list, header_lines, running, retrying, columns, rows)
      |> case do
        {tail, _, _} -> {tail, total_lines, nil}
      end
    else
      pane_lines = slice_log_lines(log_lines, pane_budget, display_log_view.scroll)
      pane_title = format_pane_title(display_log_view, running)

      tail =
        running_to_log_spacer(running) ++
          [
          colorize("├─ #{pane_title}", @ansi_bold)
        ] ++
          metadata_lines ++
          pane_lines ++
          queued_section_lines(queued_lines) ++
          [closing_border()] ++
          input_section_lines

      cursor_position =
        case input_cursor do
          {cursor_row, cursor_col} ->
            {length(List.flatten(header_lines ++ tail)) - length(input_section_lines) + cursor_row, cursor_col}
        end

      {tail, total_lines, cursor_position}
    end
  end

  defp format_log_metadata(log_view, running, _columns) do
    entry = running_entry_for_identifier(running, log_view.issue_identifier)
    issue_url = Map.get(entry || %{}, :url)

    [
      metadata_value_line("URL", issue_url || "—", if(is_binary(issue_url), do: @ansi_cyan, else: @ansi_gray)),
      "│"
    ]
  end

  defp metadata_value_line(label, value, value_color) do
    colorize("│   ", @ansi_gray) <>
      colorize("#{label}: ", @ansi_bold) <>
      colorize(value, value_color)
  end

  defp queued_section_lines([]), do: []
  defp queued_section_lines(queued_lines), do: ["│"] ++ queued_lines

  defp read_log_messages(%{workspace_path: workspace_path}) do
    workspace_path
    |> AgentLog.workspace_log_path()
    |> AgentLog.read()
    |> AgentLog.parse()
  end

  defp log_message_lines(messages, columns) do
    inner_width = max(20, columns - @log_pane_chrome_width)

    lines =
      Enum.flat_map(messages, fn message ->
        style = log_message_style(message)
        header = format_log_message_header(message, style)
        body_lines = wrap_log_body(message.body, inner_width)
        [header | Enum.map(body_lines, &("│       " <> colorize(&1, style.body)))]
      end)

    {lines, length(lines)}
  end

  # Three primary message styles:
  #
  #   * operator — manual messages typed by the human operator. Bright white
  #     so they stand out from the surrounding gray-and-coloured chrome.
  #   * prompt   — Symphony-generated input to the agent (initial prompt and
  #     continuation guidance from `PromptBuilder`).
  #   * agent    — the agent's own reasoning / output.
  #
  # System notices and tool calls keep dedicated styles so they remain
  # visually distinct from the three primary categories.
  defp log_message_style(%{role: role, title: title}) do
    case {role, title} do
      {"operator", _} -> operator_style()
      {"user", "Executor"} -> operator_style()
      {"user", _} -> prompt_style()
      {"assistant", _} -> agent_style()
      {"tool", _} -> tool_style()
      _ -> system_style()
    end
  end

  defp operator_style do
    %{label: "you", label_color: @ansi_white <> @ansi_bold, timestamp: @ansi_light_magenta, body: @ansi_white}
  end

  defp prompt_style do
    %{label: "symphony", label_color: @ansi_light_cyan <> @ansi_bold, timestamp: @ansi_cyan, body: @ansi_cyan}
  end

  defp agent_style do
    %{label: "agent", label_color: @ansi_light_green <> @ansi_bold, timestamp: @ansi_green, body: @ansi_light_green}
  end

  defp tool_style do
    %{label: "tool", label_color: @ansi_yellow <> @ansi_bold, timestamp: @ansi_orange, body: @ansi_orange}
  end

  defp system_style do
    %{label: "system", label_color: @ansi_magenta <> @ansi_bold, timestamp: @ansi_gray, body: @ansi_gray}
  end

  defp format_log_message_header(%{title: title, timestamp: timestamp}, style) do
    "│   " <>
      colorize("[#{shorten_timestamp(timestamp)}] ", style.timestamp) <>
      colorize(style.label, style.label_color) <>
      colorize(" · ", @ansi_gray) <>
      colorize(title, style.body <> @ansi_bold)
  end

  defp shorten_timestamp(ts) when is_binary(ts) do
    case Regex.run(~r/T(\d{2}:\d{2}:\d{2})/, ts) do
      [_, time] -> time
      _ -> ts
    end
  end

  defp shorten_timestamp(other), do: to_string(other)

  defp wrap_log_body(body, width) when is_binary(body) and width > 0 do
    body
    |> String.split("\n", trim: false)
    |> Enum.flat_map(&wrap_line(&1, width))
  end

  defp wrap_log_body(body, _width), do: [to_string(body)]

  defp wrap_line("", _width), do: [""]

  defp wrap_line(line, width) do
    line
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
  end

  defp slice_log_lines(lines, budget, scroll) when budget > 0 do
    total = length(lines)

    if total <= budget do
      lines
    else
      max_scroll = total - budget
      bounded_scroll = scroll |> min(max_scroll) |> max(0)
      start_index = total - budget - bounded_scroll
      Enum.slice(lines, start_index, budget)
    end
  end

  defp slice_log_lines(_lines, _budget, _scroll), do: []

  defp format_pane_title(%{issue_identifier: id} = log_view, running) do
    entry = running_entry_for_identifier(running, id)
    title = log_view.title || Map.get(entry || %{}, :title) || "—"

    state_part =
      case entry do
        nil -> " (finished)"
        entry -> " (#{entry.state})"
      end

    case log_view.workspace_path do
      nil -> "Agent log: #{id} - #{title}#{state_part} — no local workspace"
      _ -> "Agent log: #{id} - #{title}#{state_part}"
    end
  end

  defp running_entry_for_identifier(running, id) do
    Enum.find(running, &(to_string(&1.identifier) == to_string(id)))
  end

  defp format_input_section(log_view, columns) do
    inner_width = max(20, columns - 4)
    composer = Map.get(log_view, :composer, fresh_composer())
    {prompt_lines, {cursor_row, cursor_col}} = composer_prompt_lines(composer, inner_width - 2)

    status =
      cond do
        is_binary(composer.last_error) ->
          {"error: #{composer.last_error}", :error}

        is_integer(composer.pending_request_id) ->
          {"sent; waiting for agent turn", :pending}

        Map.get(log_view, :mode, :typing) == :browsing ->
          {"Tab returns to chat · J/K move agents · Space opens selected log · Esc closes log · Ctrl-C pauses", :help}

        true ->
          {"Enter sends · Esc closes log · Ctrl-C pauses · Shift-Enter newline", :help}
      end

    lines =
      [
        input_panel_blank_line(columns),
        Enum.map(prompt_lines, &input_panel_content_line("  " <> &1, columns)),
        input_panel_blank_line(columns),
        input_help_line(elem(status, 0), elem(status, 1), columns)
      ]
      |> List.flatten()

    {lines, {cursor_row + 1, cursor_col + 2}}
  end

  defp input_panel_blank_line(columns), do: input_panel_content_line("", columns)

  defp input_panel_content_line(content, columns) do
    {bg, fg, _help} = input_panel_palette()
    visible_width = max(0, columns)
    padded = String.pad_trailing(content, visible_width)
    bg <> fg <> padded <> @ansi_reset
  end

  defp input_help_line(content, variant, columns) do
    {_bg, _fg, help_color} = input_panel_palette()

    color =
      case variant do
        :error -> @ansi_red
        :pending -> @ansi_yellow
        _ -> help_color
      end

    colorize(String.pad_trailing(content, max(0, columns)), color)
  end

  defp input_panel_palette do
    if terminal_dark_mode?() do
      {@ansi_input_dark_bg, @ansi_input_dark_fg, @ansi_input_help_dark}
    else
      {@ansi_input_light_bg, @ansi_input_light_fg, @ansi_input_help_light}
    end
  end

  defp terminal_dark_mode? do
    case System.get_env("COLORFGBG") do
      nil ->
        true

      value ->
        value
        |> String.split(";", trim: true)
        |> List.last()
        |> dark_background_code?()
    end
  end

  defp dark_background_code?(bg) when is_binary(bg) do
    case Integer.parse(bg) do
      {number, ""} -> number < 8
      _ -> true
    end
  end

  defp dark_background_code?(_bg), do: true

  defp format_queued_message_lines(log_view, running, columns, messages) do
    entry = running_entry_for_identifier(running, log_view.issue_identifier)

    queued_messages =
      entry
      |> then(&Map.get(&1 || %{}, :pending_operator_messages, []))
      |> merge_local_pending_messages(Map.get(log_view, :composer, fresh_composer()))
      |> reject_logged_operator_messages(messages)

    inner_width = max(20, columns - 8)

    case queued_messages do
      [] ->
        []

      _ ->
        title_line = "│ " <> colorize("Queued input", @ansi_gray <> @ansi_bold)

        body_lines =
          queued_messages
          |> Enum.flat_map(fn queued_message ->
            queued_message
            |> queued_message_preview()
            |> wrap_line(inner_width)
            |> Enum.map(&("│   " <> colorize(&1, @ansi_gray)))
          end)

        [title_line | body_lines]
    end
  end

  defp queued_message_preview(%{text: text, status: :delivered}), do: "sending: #{text}"
  defp queued_message_preview(%{text: text}), do: "queued: #{text}"
  defp queued_message_preview(_queued_message), do: "queued"

  defp merge_local_pending_messages(queued_messages, composer) when is_list(queued_messages) do
    queued_ids = MapSet.new(queued_messages, &Map.get(&1, :id))

    local_messages =
      composer
      |> Map.get(:local_pending_messages, [])
      |> Enum.reject(&(Map.get(&1, :id) in queued_ids))

    queued_messages ++ local_messages
  end

  defp reject_logged_operator_messages(queued_messages, messages) do
    {filtered_messages, _remaining_counts} =
      Enum.reduce(queued_messages, {[], logged_operator_message_counts(messages)}, fn queued_message, {acc, logged_counts} ->
        text = normalize_operator_text(Map.get(queued_message, :text))

        case Map.get(logged_counts, text, 0) do
          count when is_integer(count) and count > 0 ->
            {acc, Map.put(logged_counts, text, count - 1)}

          _ ->
            {[queued_message | acc], logged_counts}
        end
      end)

    Enum.reverse(filtered_messages)
  end

  defp logged_operator_message_counts(messages) do
    Enum.reduce(messages, %{}, fn message, counts ->
      if operator_log_message?(message) do
        Map.update(counts, normalize_operator_text(message.body), 1, &(&1 + 1))
      else
        counts
      end
    end)
  end

  defp reconcile_log_view_with_logged_operator_messages(log_view, running, messages) do
    composer = Map.get(log_view, :composer, fresh_composer())

    case composer do
      %{pending_request_id: request_id} when is_integer(request_id) ->
        entry = running_entry_for_identifier(running, log_view.issue_identifier)
        visible_messages = Map.get(entry || %{}, :pending_operator_messages, [])
        local_messages = Map.get(composer, :local_pending_messages, [])

        pending_message =
          Enum.find(visible_messages ++ local_messages, &(Map.get(&1, :id) == request_id))

        if pending_message && operator_text_logged?(Map.get(pending_message, :text), messages) do
          %{
            log_view
            | composer:
                composer
                |> Map.put(:pending_request_id, nil)
                |> Map.put(:local_pending_messages, [])
          }
        else
          log_view
        end

      _ ->
        log_view
    end
  end

  defp operator_text_logged?(text, messages) do
    normalized_text = normalize_operator_text(text)
    Map.get(logged_operator_message_counts(messages), normalized_text, 0) > 0
  end

  defp operator_log_message?(%{role: "operator"}), do: true
  defp operator_log_message?(%{role: "user", title: "Executor"}), do: true
  defp operator_log_message?(_message), do: false

  defp normalize_operator_text(text) when is_binary(text), do: String.trim(text)
  defp normalize_operator_text(text), do: text |> to_string() |> String.trim()

  # credo:disable-for-next-line
  defp format_two_pane_header(
         agent_count,
         max_agents,
         agent_seconds_running,
         _rate_limits,
         polling,
         columns
       ) do
    left_lines = [
      colorize("│ Agents: ", @ansi_bold) <>
        colorize(Config.agent_kind(), @ansi_cyan) <>
        colorize(" ", @ansi_gray) <>
        colorize("(#{agent_count}", @ansi_gray) <>
        colorize("/", @ansi_gray) <>
        colorize("#{max_agents})", @ansi_gray),
      colorize("│ Runtime: ", @ansi_bold) <>
        colorize(format_runtime_seconds(agent_seconds_running), @ansi_magenta)
    ]

    right_lines =
      right_project_lines() ++
        [right_refresh_line(polling)]

    rows = pair_pane_lines(left_lines, right_lines, columns)
    [format_title_row(columns) | rows]
  end

  defp format_title_row(columns) do
    _ = columns
    colorize("╭─ SYMPHONY STATUS", @ansi_bold)
  end

  defp running_header_row do
    case dashboard_url() do
      url when is_binary(url) ->
        colorize("├─ Running: ", @ansi_bold) <> colorize(url, @ansi_cyan)

      _ ->
        colorize("├─ Running", @ansi_bold)
    end
  end

  defp pair_pane_lines(left_lines, right_lines, columns) do
    count = max(length(left_lines), length(right_lines))
    left_width = max(24, div(max(columns - 3, 0), 2))

    Enum.map(0..(count - 1), fn i ->
      left = Enum.at(left_lines, i) || "│"
      right = Enum.at(right_lines, i) || ""

      "#{pad_visible(left, left_width)} #{colorize("│", @ansi_gray)} #{right}"
    end)
  end

  defp pad_visible(string, width) when is_binary(string) do
    pad = max(0, width - visible_length(string))
    string <> String.duplicate(" ", pad)
  end

  defp visible_length(string) when is_binary(string) do
    string
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.length()
  end

  defp right_project_lines do
    [colorize("Project: ", @ansi_bold) <> project_display_url()]
  end

  defp right_refresh_line(%{checking?: true}) do
    colorize("Next refresh: ", @ansi_bold) <> colorize("checking now…", @ansi_cyan)
  end

  defp right_refresh_line(%{next_poll_in_ms: due_in_ms}) when is_integer(due_in_ms) do
    due_in_ms = max(due_in_ms, 0)
    seconds = div(due_in_ms + 999, 1000)
    colorize("Next refresh: ", @ansi_bold) <> colorize("#{seconds}s", @ansi_cyan)
  end

  defp right_refresh_line(_) do
    colorize("Next refresh: ", @ansi_bold) <> colorize("n/a", @ansi_gray)
  end

  defp format_project_link_lines do
    project_part = project_display_url()

    project_line = colorize("│ Project: ", @ansi_bold) <> project_part

    case dashboard_url() do
      url when is_binary(url) ->
        [project_line, colorize("│ Dashboard: ", @ansi_bold) <> colorize(url, @ansi_cyan)]

      _ ->
        [project_line]
    end
  end

  defp project_display_url do
    case Tracker.project_identity() do
      identity when is_binary(identity) and identity != "" ->
        colorize(project_label(Config.tracker_kind(), identity), @ansi_cyan)

      _ ->
        colorize("n/a", @ansi_gray)
    end
  end

  defp project_label("github", repo), do: repo
  defp project_label(_tracker_kind, slug), do: slug

  defp format_project_refresh_line(_) do
    colorize("│ Next refresh: ", @ansi_bold) <> colorize("n/a", @ansi_gray)
  end

  defp dashboard_url do
    dashboard_url(Config.server_host(), Config.server_port(), HttpServer.bound_port())
  end

  defp dashboard_url(_host, nil, _bound_port), do: nil

  defp dashboard_url(host, configured_port, bound_port) do
    port = bound_port || configured_port

    if is_integer(port) and port > 0 do
      "http://#{dashboard_url_host(host)}:#{port}/"
    else
      nil
    end
  end

  defp dashboard_url_host(host) when host in ["0.0.0.0", "::", "[::]", ""], do: "127.0.0.1"

  defp dashboard_url_host(host) when is_binary(host) do
    trimmed_host = String.trim(host)

    cond do
      trimmed_host in ["0.0.0.0", "::", "[::]", ""] ->
        "127.0.0.1"

      String.starts_with?(trimmed_host, "[") and String.ends_with?(trimmed_host, "]") ->
        trimmed_host

      String.contains?(trimmed_host, ":") ->
        "[#{trimmed_host}]"

      true ->
        trimmed_host
    end
  end

  defp render_to_terminal(content, cursor_position) do
    cursor_commands =
      case cursor_position do
        {row, col} when is_integer(row) and is_integer(col) and row > 0 and col > 0 ->
          [IO.ANSI.cursor(row, col), "\e[?25h"]

        _ ->
          ["\e[?25l"]
      end

    IO.write([
      IO.ANSI.home(),
      IO.ANSI.clear(),
      normalize_status_lines(content),
      cursor_commands
    ])
  end

  defp update_token_samples(samples, now_ms, total_tokens) do
    prune_graph_samples([{now_ms, total_tokens} | samples], now_ms)
  end

  defp prune_samples(samples, now_ms) do
    min_timestamp = now_ms - @throughput_window_ms
    Enum.filter(samples, fn {timestamp, _} -> timestamp >= min_timestamp end)
  end

  defp prune_graph_samples(samples, now_ms) do
    min_timestamp = now_ms - max(@throughput_window_ms, @throughput_graph_window_ms)
    Enum.filter(samples, fn {timestamp, _} -> timestamp >= min_timestamp end)
  end

  @doc false
  @spec rolling_tps([{integer(), integer()}], integer(), integer()) :: float()
  def rolling_tps(samples, now_ms, current_tokens) do
    samples = [{now_ms, current_tokens} | samples]
    samples = prune_samples(samples, now_ms)

    case samples do
      [] ->
        0.0

      [_one] ->
        0.0

      _ ->
        first = List.last(samples)
        {start_ms, start_tokens} = first
        elapsed_ms = now_ms - start_ms
        delta_tokens = max(0, current_tokens - start_tokens)

        if elapsed_ms <= 0 do
          0.0
        else
          delta_tokens / (elapsed_ms / 1000.0)
        end
    end
  end

  @doc false
  @spec throttled_tps(integer() | nil, float() | nil, integer(), [{integer(), integer()}], integer()) ::
          {integer(), float()}
  def throttled_tps(last_second, last_value, now_ms, token_samples, current_tokens) do
    second = div(now_ms, 1000)

    if is_integer(last_second) and last_second == second and is_number(last_value) do
      {second, last_value}
    else
      {second, rolling_tps(token_samples, now_ms, current_tokens)}
    end
  end

  @doc false
  @spec format_timestamp_for_test(DateTime.t()) :: String.t()
  def format_timestamp_for_test(%DateTime{} = datetime), do: format_timestamp(datetime)

  @doc false
  @spec format_snapshot_content_for_test(term(), number(), integer() | nil, non_neg_integer() | nil, keyword()) ::
          String.t()
  def format_snapshot_content_for_test(snapshot_data, tps, terminal_columns \\ nil, selected_index \\ nil, opts \\ []) do
    base = [
      terminal_columns: terminal_columns,
      selected_index: selected_index
    ]

    {content, _log_total_lines, _cursor_position} =
      format_snapshot_content(snapshot_data, tps, Keyword.merge(base, opts))

    content
  end

  @doc false
  @spec renderable_snapshot_data_for_test(term(), term(), view()) :: term()
  def renderable_snapshot_data_for_test(snapshot_data, last_snapshot_data, view),
    do: renderable_snapshot_data(snapshot_data, last_snapshot_data, view)

  @doc false
  @spec dashboard_url_for_test(String.t(), non_neg_integer() | nil, non_neg_integer() | nil) ::
          String.t() | nil
  def dashboard_url_for_test(host, configured_port, bound_port),
    do: dashboard_url(host, configured_port, bound_port)

  defp snapshot_payload do
    if Process.whereis(Orchestrator) do
      case Orchestrator.snapshot() do
        %{
          running: running,
          retrying: retrying,
          agent_totals: agent_totals
        } = snapshot
        when is_list(running) and is_list(retrying) ->
          {:ok,
           %{
             running: running,
             retrying: retrying,
             agent_totals: agent_totals,
             rate_limits: Map.get(snapshot, :rate_limits),
             polling: Map.get(snapshot, :polling)
           }}

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp format_running_rows(running, selected_index) do
    if running == [] do
      [
        "│  " <> colorize("No active agents", @ansi_gray),
        "│"
      ]
    else
      running
      |> Enum.sort_by(& &1.identifier)
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        format_running_summary(entry, selected_index == index)
      end)
    end
  end

  # credo:disable-for-next-line
  defp format_running_summary(running_entry, selected? \\ false) do
    issue = format_cell(running_entry.identifier || "unknown", @running_id_width)
    tag = format_cell(display_tag(Map.get(running_entry, :tag)), @running_tag_width)
    state = Map.get(running_entry, :work_state) || get_in(running_entry, [:control, :status]) || :working
    state_display = format_cell(work_state_label(state), @running_state_width)
    title = format_cell(Map.get(running_entry, :title) || "", @running_issue_width)
    runtime_seconds = running_entry.runtime_seconds || 0
    turn_count = Map.get(running_entry, :turn_count, 0)
    age = format_cell(format_runtime_and_turns(runtime_seconds, turn_count), @running_age_width)

    status_color =
      case state do
        :paused -> @ansi_yellow
        "paused" -> @ansi_yellow
        _ -> @ansi_green
      end

    [
      "│ ",
      selection_marker(status_color, selected?),
      " ",
      colorize(issue, @ansi_cyan),
      " ",
      colorize(tag, @ansi_gray),
      " ",
      colorize(state_display, status_color),
      " ",
      colorize(title, @ansi_cyan),
      " ",
      colorize(age, @ansi_magenta)
    ]
    |> Enum.join("")
  end

  @doc false
  @spec format_running_summary_for_test(map(), integer() | nil) :: String.t()
  def format_running_summary_for_test(running_entry, _terminal_columns \\ nil),
    do: format_running_summary(running_entry)

  @doc false
  @spec reconcile_log_view_with_snapshot_for_test(t(), term()) :: t()
  def reconcile_log_view_with_snapshot_for_test(state, snapshot_data),
    do: reconcile_log_view_with_snapshot(state, snapshot_data)

  @doc false
  @spec format_tps_for_test(number()) :: String.t()
  def format_tps_for_test(value), do: format_tps(value)

  @doc false
  @spec tps_graph_for_test([{integer(), integer()}], integer(), integer()) :: String.t()
  def tps_graph_for_test(samples, now_ms, current_tokens), do: tps_graph(samples, now_ms, current_tokens)

  defp format_retry_rows(retrying) do
    if retrying == [] do
      ["│  " <> colorize("No queued retries", @ansi_gray)]
    else
      retrying
      |> Enum.sort_by(& &1.due_in_ms)
      |> Enum.map_join(", ", &format_retry_summary/1)
      |> String.split(", ")
    end
  end

  defp format_retry_summary(retry_entry) do
    issue_id = retry_entry.issue_id || "unknown"
    identifier = retry_entry.identifier || issue_id
    attempt = retry_entry.attempt || 0
    due_in_ms = retry_entry.due_in_ms || 0
    error = format_retry_error(retry_entry.error)

    "│  #{colorize("↻", @ansi_orange)} " <>
      colorize("#{identifier}", @ansi_red) <>
      " " <>
      colorize("attempt=#{attempt}", @ansi_yellow) <>
      colorize(" in ", @ansi_dim) <>
      colorize(next_in_words(due_in_ms), @ansi_cyan) <>
      error
  end

  defp next_in_words(due_in_ms) when is_integer(due_in_ms) do
    secs = div(due_in_ms, 1000)
    millis = rem(due_in_ms, 1000)
    "#{secs}.#{String.pad_leading(to_string(millis), 3, "0")}s"
  end

  defp next_in_words(_), do: "n/a"

  defp format_retry_error(error) when is_binary(error) do
    sanitized =
      error
      |> String.replace("\\r\\n", " ")
      |> String.replace("\\r", " ")
      |> String.replace("\\n", " ")
      |> String.replace("\r\n", " ")
      |> String.replace("\r", " ")
      |> String.replace("\n", " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if sanitized == "" do
      ""
    else
      " " <> colorize("error=#{truncate(sanitized, 96)}", @ansi_dim)
    end
  end

  defp format_retry_error(_), do: ""

  defp format_runtime_seconds(seconds) when is_integer(seconds) do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_runtime_seconds(seconds) when is_binary(seconds), do: seconds
  defp format_runtime_seconds(_), do: "0m 0s"

  defp dashboard_runtime_seconds(running, agent_totals) when is_list(running) and is_map(agent_totals) do
    running_seconds =
      running
      |> Enum.map(&Map.get(&1, :runtime_seconds, 0))
      |> Enum.filter(&is_integer/1)
      |> Enum.sum()

    running_seconds + Map.get(agent_totals, :seconds_running, 0)
  end

  defp dashboard_runtime_seconds(_running, agent_totals) when is_map(agent_totals),
    do: Map.get(agent_totals, :seconds_running, 0)

  defp dashboard_runtime_seconds(_running, _agent_totals), do: 0

  defp format_runtime_and_turns(seconds, turn_count) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(seconds)} / #{turn_count}"
  end

  defp format_runtime_and_turns(seconds, _turn_count), do: format_runtime_seconds(seconds)

  defp display_tag(nil), do: "—"
  defp display_tag(""), do: "—"
  defp display_tag(tag) when is_binary(tag), do: String.replace_prefix(tag, "agent:", "")
  defp display_tag(tag), do: tag |> to_string() |> display_tag()

  defp running_table_header_row do
    header =
      [
        format_cell("ID", @running_id_width),
        format_cell("TAG", @running_tag_width),
        format_cell("STATE", @running_state_width),
        format_cell("ISSUE", @running_issue_width),
        format_cell("AGE / TURN", @running_age_width)
      ]
      |> Enum.join(" ")

    "│   " <> colorize(header, @ansi_gray)
  end

  defp running_table_separator_row do
    separator_width =
      @running_id_width +
        @running_tag_width +
        @running_state_width +
        @running_issue_width +
        @running_age_width + 3

    "│   " <> colorize(String.duplicate("─", separator_width), @ansi_gray)
  end

  defp work_state_label(:paused), do: "paused"
  defp work_state_label("paused"), do: "paused"
  defp work_state_label(_state), do: "working"

  defp terminal_columns do
    case :io.columns() do
      {:ok, columns} when is_integer(columns) and columns > 0 ->
        columns

      _ ->
        terminal_columns_from_env()
    end
  end

  defp terminal_columns_from_env do
    case System.get_env("COLUMNS") do
      nil ->
        @default_terminal_columns

      value ->
        case Integer.parse(String.trim(value)) do
          {columns, ""} when columns > 0 -> columns
          _ -> @default_terminal_columns
        end
    end
  end

  defp terminal_rows do
    case :io.rows() do
      {:ok, rows} when is_integer(rows) and rows > 0 ->
        rows

      _ ->
        terminal_rows_from_env()
    end
  end

  defp terminal_rows_from_env do
    case System.get_env("ROWS") do
      nil ->
        @default_terminal_rows

      value ->
        case Integer.parse(String.trim(value)) do
          {rows, ""} when rows > 0 -> rows
          _ -> @default_terminal_rows
        end
    end
  end

  defp format_cell(value, width) do
    value =
      value
      |> to_string()
      |> String.replace("\n", " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> truncate_plain(width)

    String.pad_trailing(value, width)
  end

  defp truncate_plain(value, width) do
    if byte_size(value) <= width do
      value
    else
      String.slice(value, 0, width - 3) <> "..."
    end
  end

  defp group_thousands(value) when is_binary(value) do
    sign = if String.starts_with?(value, "-"), do: "-", else: ""
    unsigned = if sign == "", do: value, else: String.slice(value, 1, String.length(value) - 1)

    unsigned
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
    |> prepend(sign)
  end

  defp prepend("", value), do: value
  defp prepend(prefix, value), do: prefix <> value

  defp format_tps(value) when is_number(value) do
    value
    |> trunc()
    |> Integer.to_string()
    |> group_thousands()
  end

  defp tps_graph(samples, now_ms, current_tokens) do
    bucket_ms = div(@throughput_graph_window_ms, @throughput_graph_columns)
    active_bucket_start = div(now_ms, bucket_ms) * bucket_ms
    graph_window_start = active_bucket_start - (@throughput_graph_columns - 1) * bucket_ms

    rates =
      [{now_ms, current_tokens} | samples]
      |> prune_graph_samples(now_ms)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{start_ms, start_tokens}, {end_ms, end_tokens}] ->
        elapsed_ms = end_ms - start_ms
        delta_tokens = max(0, end_tokens - start_tokens)
        tps = if elapsed_ms <= 0, do: 0.0, else: delta_tokens / (elapsed_ms / 1000.0)
        {end_ms, tps}
      end)

    bucketed_tps =
      0..(@throughput_graph_columns - 1)
      |> Enum.map(fn bucket_idx ->
        bucket_start = graph_window_start + bucket_idx * bucket_ms
        bucket_end = bucket_start + bucket_ms
        last_bucket? = bucket_idx == @throughput_graph_columns - 1

        values =
          rates
          |> Enum.filter(fn {timestamp, _tps} ->
            in_bucket?(timestamp, bucket_start, bucket_end, last_bucket?)
          end)
          |> Enum.map(fn {_timestamp, tps} -> tps end)

        if values == [] do
          0.0
        else
          Enum.sum(values) / length(values)
        end
      end)

    max_tps = Enum.max(bucketed_tps, fn -> 0.0 end)

    bucketed_tps
    |> Enum.map_join(fn value ->
      index =
        if max_tps <= 0 do
          0
        else
          round(value / max_tps * (length(@sparkline_blocks) - 1))
        end

      Enum.at(@sparkline_blocks, index, "▁")
    end)
  end

  defp in_bucket?(timestamp, bucket_start, bucket_end, true),
    do: timestamp >= bucket_start and timestamp <= bucket_end

  defp in_bucket?(timestamp, bucket_start, bucket_end, false),
    do: timestamp >= bucket_start and timestamp < bucket_end

  defp map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp map_value(_map, _keys), do: nil

  defp selection_marker(color_code, true), do: colorize("▶", color_code)
  defp selection_marker(_color_code, false), do: " "

  defp move_selected_index(selected_index, {:ok, %{running: running}}, direction) when running != [] do
    count = length(running)
    current_index = selected_index || 0

    current_index
    |> Kernel.+(direction)
    |> Integer.mod(count)
  end

  defp move_selected_index(_selected_index, _snapshot_data, _direction), do: nil

  defp running_entry_at({:ok, %{running: running}}, index) when is_integer(index) and running != [] do
    sorted = Enum.sort_by(running, & &1.identifier)
    Enum.at(sorted, index)
  end

  defp running_entry_at(_snapshot_data, _index), do: nil

  defp running_to_log_spacer([]), do: []
  defp running_to_log_spacer(_running), do: ["│"]

  defp build_log_view(entry) do
    {:log,
     %{
       issue_identifier: to_string(entry.identifier),
       workspace_path: Map.get(entry, :workspace_path),
       title: Map.get(entry, :title),
       scroll: 0,
       last_total_lines: 0,
       mode: :typing,
       composer: fresh_composer()
     }}
  end

  defp update_log_view(state, log_view) do
    state
    |> Map.put(:view, {:log, log_view})
    |> Map.put(:last_snapshot_fingerprint, nil)
  end

  defp reconcile_log_view_with_snapshot(%{view: {:log, log_view}} = state, {:ok, %{running: running}})
       when is_list(running) do
    case Enum.find(running, &(to_string(&1.identifier) == log_view.issue_identifier)) do
      nil ->
        state

      running_entry ->
        reconciled_log_view = %{
          log_view
          | workspace_path: Map.get(running_entry, :workspace_path) || log_view.workspace_path,
            title: Map.get(running_entry, :title) || log_view.title,
            composer: reconcile_composer_with_running_entry(log_view.composer, running_entry)
        }

        Map.put(state, :view, {:log, reconciled_log_view})
    end
  end

  defp reconcile_log_view_with_snapshot(state, _snapshot_data), do: state

  defp fresh_composer do
    %{buffer: "", cursor_offset: 0, pending_request_id: nil, last_error: nil, local_pending_messages: []}
  end

  defp reconcile_composer_with_running_entry(%{pending_request_id: request_id} = composer, running_entry)
       when is_integer(request_id) do
    visible_messages = Map.get(running_entry, :pending_operator_messages, [])
    request_visible? = Enum.any?(visible_messages, &(Map.get(&1, :id) == request_id))

    request_locally_pending? =
      composer
      |> Map.get(:local_pending_messages, [])
      |> Enum.any?(&(Map.get(&1, :id) == request_id))

    cond do
      request_visible? ->
        Map.put(composer, :local_pending_messages, [])

      request_locally_pending? ->
        composer

      true ->
        composer
        |> Map.put(:pending_request_id, nil)
        |> Map.put(:local_pending_messages, [])
    end
  end

  defp reconcile_composer_with_running_entry(composer, _running_entry), do: composer

  defp preserve_previous_running_snapshot?(running, previous_running, log_view)
       when is_list(running) and is_list(previous_running) and is_map(log_view) do
    previous_running != [] and
      missing_running_entry?(running, Map.get(log_view, :issue_identifier)) and
      has_running_entry?(previous_running, Map.get(log_view, :issue_identifier)) and
      composer_has_pending_submission?(Map.get(log_view, :composer))
  end

  defp missing_running_entry?(running, issue_identifier) when is_list(running) and is_binary(issue_identifier) do
    not has_running_entry?(running, issue_identifier)
  end

  defp missing_running_entry?(_running, _issue_identifier), do: false

  defp has_running_entry?(running, issue_identifier) when is_list(running) and is_binary(issue_identifier) do
    Enum.any?(running, &(to_string(Map.get(&1, :identifier)) == issue_identifier))
  end

  defp has_running_entry?(_running, _issue_identifier), do: false

  defp composer_has_pending_submission?(%{pending_request_id: request_id}) when is_integer(request_id), do: true

  defp composer_has_pending_submission?(%{local_pending_messages: messages}) when is_list(messages),
    do: messages != []

  defp composer_has_pending_submission?(_composer), do: false

  defp insert_text_at_cursor(composer, text) when is_binary(text) do
    {before_text, after_text} = split_buffer_at_cursor(composer.buffer, Map.get(composer, :cursor_offset, 0))
    inserted_length = grapheme_length(text)

    composer
    |> Map.put(:buffer, before_text <> text <> after_text)
    |> Map.put(:cursor_offset, Map.get(composer, :cursor_offset, 0) + inserted_length)
  end

  defp backspace_at_cursor(%{buffer: buffer} = composer) do
    cursor_offset = Map.get(composer, :cursor_offset, 0)

    if cursor_offset <= 0 do
      composer
    else
      {before_text, after_text} = split_buffer_at_cursor(buffer, cursor_offset)
      trimmed_before = drop_last_grapheme(before_text)

      composer
      |> Map.put(:buffer, trimmed_before <> after_text)
      |> Map.put(:cursor_offset, cursor_offset - 1)
    end
  end

  defp move_cursor(composer, delta) when delta in [-1, 1] do
    limit = grapheme_length(composer.buffer)
    next_offset = Map.get(composer, :cursor_offset, 0) + delta
    Map.put(composer, :cursor_offset, max(0, min(limit, next_offset)))
  end

  defp composer_prompt_lines(composer, width) do
    prompt = "› " <> composer.buffer
    cursor_index = min(Map.get(composer, :cursor_offset, 0) + 2, grapheme_length(prompt))
    prompt_lines = prompt |> String.split("\n", trim: false) |> Enum.flat_map(&wrap_line(&1, width))
    cursor_position = wrapped_cursor_position(prompt, cursor_index, width)

    {prompt_lines, cursor_position}
  end

  defp wrapped_cursor_position(text, cursor_index, width) do
    graphemes = String.graphemes(text)
    bounded_index = max(0, min(length(graphemes), cursor_index))
    {before_cursor, _rest} = Enum.split(graphemes, bounded_index)
    before_text = Enum.join(before_cursor)
    lines = String.split(before_text, "\n", trim: false)
    {prior_lines, [last_line]} = Enum.split(lines, -1)

    row =
      Enum.reduce(prior_lines, 0, fn line, acc ->
        acc + wrapped_line_count(line, width)
      end) + div(grapheme_length(last_line), width) + 1

    col = rem(grapheme_length(last_line), width) + 1
    {row, col}
  end

  defp wrapped_line_count(line, width), do: div(grapheme_length(line), width) + 1

  defp split_buffer_at_cursor(buffer, cursor_offset) do
    graphemes = String.graphemes(buffer)
    bounded_offset = max(0, min(length(graphemes), cursor_offset))
    {before_text, after_text} = Enum.split(graphemes, bounded_offset)
    {Enum.join(before_text), Enum.join(after_text)}
  end

  defp grapheme_length(buffer) do
    buffer
    |> String.graphemes()
    |> length()
  end

  defp drop_last_grapheme(""), do: ""

  defp drop_last_grapheme(buffer) do
    buffer
    |> String.graphemes()
    |> Enum.drop(-1)
    |> Enum.join()
  end

  defp format_operator_error(:no_running_agent), do: "agent is no longer running"
  defp format_operator_error(:empty_message), do: "message is empty"
  defp format_operator_error(:message_too_long), do: "message is too long"
  defp format_operator_error(:interrupt_not_supported), do: "interrupt is not available right now"
  defp format_operator_error(:timeout), do: "send timed out"
  defp format_operator_error(:unavailable), do: "orchestrator unavailable"
  defp format_operator_error(reason), do: inspect(reason)

  defp retarget_log_view(%{view: {:log, _log_view}} = state, _snapshot_data, _index), do: state

  defp retarget_log_view(state, _snapshot_data, _index), do: state

  defp clamped_scroll(%{scroll: scroll, last_total_lines: total}, :up) do
    # Up = move toward older entries (increase offset from bottom)
    min(scroll + 1, max(0, total))
  end

  defp clamped_scroll(%{scroll: scroll}, :down) do
    # Down = move toward newer entries (decrease offset toward 0)
    max(scroll - 1, 0)
  end

  defp update_log_view_total_lines(%{view: {:log, log_view}} = state, total_lines)
       when is_integer(total_lines) do
    Map.put(state, :view, {:log, %{log_view | last_total_lines: total_lines}})
  end

  defp update_log_view_total_lines(state, _total_lines), do: state

  defp snapshot_total_tokens({:ok, %{agent_totals: agent_totals}}) when is_map(agent_totals) do
    Map.get(agent_totals, :total_tokens, 0)
  end

  defp snapshot_total_tokens(_snapshot_data), do: 0

  defp format_timestamp(datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_string()
  end

  defp normalize_status_lines(content) do
    content
  end

  defp closing_border, do: "╰─"

  defp colorize(value, code) do
    "#{code}#{value}#{@ansi_reset}"
  end

  @doc false
  @spec humanize_codex_message(term()) :: String.t()
  def humanize_codex_message(nil), do: "no message from #{SymphonyElixir.Config.agent_kind()} yet"

  def humanize_codex_message(%{event: event, message: message}) do
    payload = unwrap_codex_message_payload(message)

    (humanize_codex_event(event, message, payload) || humanize_codex_payload(payload))
    |> truncate(140)
  end

  def humanize_codex_message(%{message: message}) do
    message
    |> unwrap_codex_message_payload()
    |> humanize_codex_payload()
    |> truncate(140)
  end

  def humanize_codex_message(message) do
    message
    |> unwrap_codex_message_payload()
    |> humanize_codex_payload()
    |> truncate(140)
  end

  defp humanize_codex_event(:session_started, _message, payload) do
    session_id = map_value(payload, ["session_id", :session_id])

    if is_binary(session_id) do
      "session started (#{session_id})"
    else
      "session started"
    end
  end

  defp humanize_codex_event(:turn_input_required, _message, _payload), do: "turn blocked: waiting for user input"

  defp humanize_codex_event(:approval_auto_approved, message, payload) do
    method =
      map_value(payload, ["method", :method]) ||
        map_path(message, ["payload", "method"]) ||
        map_path(message, [:payload, :method])

    decision = map_value(message, ["decision", :decision])

    base =
      if is_binary(method) do
        "#{SymphonyElixir.EventHumanizer.humanize_method(method, payload)} (auto-approved)"
      else
        "approval request auto-approved"
      end

    if is_binary(decision), do: "#{base}: #{decision}", else: base
  end

  defp humanize_codex_event(:tool_input_auto_answered, message, payload) do
    answer = map_value(message, ["answer", :answer])

    base = "#{SymphonyElixir.EventHumanizer.humanize_method("item/tool/requestUserInput", payload)} (auto-answered)"

    if is_binary(answer), do: "#{base}: #{inline_text(answer)}", else: base
  end

  defp humanize_codex_event(:tool_call_completed, _message, payload),
    do: humanize_dynamic_tool_event("dynamic tool call completed", payload)

  defp humanize_codex_event(:tool_call_failed, _message, payload),
    do: humanize_dynamic_tool_event("dynamic tool call failed", payload)

  defp humanize_codex_event(:unsupported_tool_call, _message, payload),
    do: humanize_dynamic_tool_event("unsupported dynamic tool call rejected", payload)

  defp humanize_codex_event(:turn_ended_with_error, message, _payload), do: "turn ended with error: #{format_reason(message)}"
  defp humanize_codex_event(:startup_failed, message, _payload), do: "startup failed: #{format_reason(message)}"
  defp humanize_codex_event(:turn_failed, _message, payload), do: SymphonyElixir.EventHumanizer.humanize_method("turn/failed", payload)
  defp humanize_codex_event(:turn_cancelled, _message, _payload), do: "turn cancelled"
  defp humanize_codex_event(:malformed, _message, _payload), do: "malformed JSON event from codex"
  defp humanize_codex_event(_event, _message, _payload), do: nil

  defp unwrap_codex_message_payload(%{} = message) do
    cond do
      is_binary(map_value(message, ["method", :method])) -> message
      is_binary(map_value(message, ["session_id", :session_id])) -> message
      is_binary(map_value(message, ["reason", :reason])) -> message
      true -> map_value(message, ["payload", :payload]) || message
    end
  end

  defp unwrap_codex_message_payload(message), do: message

  defp humanize_codex_payload(%{} = payload) do
    case map_value(payload, ["method", :method]) do
      method when is_binary(method) ->
        SymphonyElixir.EventHumanizer.humanize_method(method, payload)

      _ ->
        cond do
          is_binary(map_value(payload, ["session_id", :session_id])) ->
            "session started (#{map_value(payload, ["session_id", :session_id])})"

          match?(%{"error" => _}, payload) ->
            "error: #{format_error_value(Map.get(payload, "error"))}"

          true ->
            payload
            |> inspect(pretty: true, limit: 30)
            |> String.replace("\n", " ")
            |> sanitize_ansi_and_control_bytes()
            |> String.trim()
        end
    end
  end

  defp humanize_codex_payload(payload) when is_binary(payload) do
    payload
    |> String.replace("\n", " ")
    |> sanitize_ansi_and_control_bytes()
    |> String.trim()
  end

  defp humanize_codex_payload(payload) do
    payload
    |> inspect(pretty: true, limit: 20)
    |> String.replace("\n", " ")
    |> sanitize_ansi_and_control_bytes()
    |> String.trim()
  end

  defp sanitize_ansi_and_control_bytes(value) when is_binary(value) do
    value
    |> String.replace(~r/\x1B\[[0-9;]*[A-Za-z]/, "")
    |> String.replace(~r/\x1B./, "")
    |> String.replace(~r/[\x00-\x1F\x7F]/, "")
  end

  defp humanize_dynamic_tool_event(base, payload) do
    case dynamic_tool_name(payload) do
      tool when is_binary(tool) ->
        trimmed = String.trim(tool)

        if trimmed == "" do
          base
        else
          "#{base} (#{trimmed})"
        end

      _ ->
        base
    end
  end

  defp dynamic_tool_name(payload) do
    map_path(payload, ["params", "tool"]) ||
      map_path(payload, ["params", "name"]) ||
      map_path(payload, [:params, :tool]) ||
      map_path(payload, [:params, :name])
  end

  defp format_error_value(%{"message" => message}) when is_binary(message), do: message
  defp format_error_value(%{message: message}) when is_binary(message), do: message
  defp format_error_value(error), do: inspect(error, limit: 10)

  defp format_reason(message) when is_map(message) do
    case map_value(message, ["reason", :reason]) do
      nil ->
        message
        |> inspect(limit: 10)
        |> inline_text()

      reason ->
        format_error_value(reason)
    end
  end

  defp format_reason(other), do: format_error_value(other)

  defp inline_text(text) when is_binary(text) do
    text
    |> String.replace("\n", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(80)
  end

  defp inline_text(other), do: other |> to_string() |> inline_text()

  defp map_path(data, [key | rest]) when is_map(data) do
    case fetch_map_key(data, key) do
      {:ok, value} when rest == [] -> value
      {:ok, value} -> map_path(value, rest)
      :error -> nil
    end
  end

  defp map_path(_data, _path), do: nil

  defp fetch_map_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        alternate = alternate_key(key)

        if alternate == key do
          :error
        else
          Map.fetch(map, alternate)
        end
    end
  end

  defp alternate_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp alternate_key(key) when is_atom(key), do: Atom.to_string(key)

  defp truncate(value, max) when byte_size(value) > max do
    value |> String.slice(0, max) |> Kernel.<>("...")
  end

  defp truncate(value, _max), do: value

  defp dashboard_enabled? do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      try do
        Mix.env() != :test
      rescue
        _ -> true
      end
    else
      true
    end
  end

  defp keyword_override(opts, key) do
    if Keyword.has_key?(opts, key), do: Keyword.fetch!(opts, key), else: nil
  end

  defp resolve_override(nil, default), do: default
  defp resolve_override(override, _default), do: override
end
