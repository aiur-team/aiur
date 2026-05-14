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
  @running_state_width 10
  @running_issue_width 26
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
          render_fun: (String.t() -> term()),
          token_samples: [{integer(), integer()}],
          last_tps_second: integer() | nil,
          last_tps_value: float() | nil,
          last_rendered_content: String.t() | nil,
          last_rendered_at_ms: integer() | nil,
          pending_content: String.t() | nil,
          flush_timer_ref: reference() | nil,
          last_snapshot_fingerprint: term() | nil,
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
    render_fun = Keyword.get(opts, :render_fun, &render_to_terminal/1)
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

    render_to_terminal(content)
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

        content ->
          state
          |> Map.put(:flush_timer_ref, nil)
          |> Map.put(:pending_content, nil)
          |> render_content(content, now_ms)
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
    composer = Map.update!(log_view.composer, :buffer, &(&1 <> text))

    state =
      state
      |> update_log_view(%{log_view | composer: %{composer | last_error: nil}})
      |> maybe_render()

    {:noreply, state}
  end

  def handle_cast({:append_text, _text}, state), do: {:noreply, state}

  def handle_cast(:backspace, %{enabled: true, view: {:log, %{mode: :typing} = log_view}} = state) do
    composer = Map.update!(log_view.composer, :buffer, &drop_last_grapheme/1)

    state =
      state
      |> update_log_view(%{log_view | composer: %{composer | last_error: nil}})
      |> maybe_render()

    {:noreply, state}
  end

  def handle_cast(:backspace, state), do: {:noreply, state}

  def handle_cast(:submit_message, %{enabled: true, view: {:log, %{mode: :typing} = log_view}} = state) do
    text = String.trim(log_view.composer.buffer)

    state =
      if text == "" do
        state
      else
        composer = submit_composer_text(log_view.issue_identifier, text, log_view.composer)

        update_log_view(state, %{log_view | composer: composer})
      end

    {:noreply, maybe_render(%{state | last_snapshot_fingerprint: nil})}
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
      {:ok, request_id} -> %{fresh_composer() | pending_request_id: request_id}
      {:error, reason} -> %{composer | last_error: format_operator_error(reason)}
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

    state =
      state
      |> Map.put(:token_samples, token_samples)
      |> reconcile_log_view_with_snapshot(snapshot_data)

    current_tokens = snapshot_total_tokens(snapshot_data)

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

    snapshot_fingerprint = {snapshot_data, state.selected_index, state.view}

    if snapshot_fingerprint != state.last_snapshot_fingerprint or periodic_rerender_due?(state, now_ms) do
      {content, log_total_lines} =
        format_snapshot_content(
          snapshot_data,
          tps,
          selected_index: state.selected_index,
          view: state.view
        )

      state
      |> update_log_view_total_lines(log_total_lines)
      |> maybe_update_snapshot_fingerprint(snapshot_fingerprint)
      |> maybe_enqueue_render(content, now_ms)
    else
      state
    end
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed rendering status dashboard: #{Exception.message(error)}")
      state
  end

  defp maybe_enqueue_render(state, content, now_ms) do
    cond do
      content == state.last_rendered_content ->
        state

      render_now?(state, now_ms) ->
        render_content(state, content, now_ms)

      true ->
        schedule_flush_render(%{state | pending_content: content}, now_ms)
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

  defp render_content(state, content, now_ms) do
    state.render_fun.(content)

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
        agent_input_tokens = Map.get(agent_totals, :input_tokens, 0)
        agent_output_tokens = Map.get(agent_totals, :output_tokens, 0)
        agent_total_tokens = Map.get(agent_totals, :total_tokens, 0)
        agent_seconds_running = Map.get(agent_totals, :seconds_running, 0)
        agent_count = length(running)
        max_agents = Config.max_concurrent_agents()
        running_rows = format_running_rows(running, selected_index)

        two_pane_rows =
          format_two_pane_header(
            agent_count,
            max_agents,
            tps,
            agent_seconds_running,
            agent_input_tokens,
            agent_output_tokens,
            agent_total_tokens,
            rate_limits,
            polling,
            resolved_columns
          )

        header_lines =
          two_pane_rows ++
            [
              colorize("├─ Running", @ansi_bold),
              "│",
              running_table_header_row(),
              running_table_separator_row()
            ] ++ running_rows

        {tail_lines, log_total_lines} =
          format_view_tail(view, header_lines, running, retrying, resolved_columns, resolved_rows)

        content =
          (header_lines ++ tail_lines)
          |> List.flatten()
          |> Enum.join("\n")

        {content, log_total_lines}

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

        {content, nil}
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

    {tail, nil}
  end

  defp format_view_tail({:log, log_view}, header_lines, running, retrying, columns, rows) do
    messages = read_log_messages(log_view)
    {log_lines, total_lines} = log_message_lines(messages, columns)

    metadata_lines = format_log_metadata(log_view, running, columns)
    header_height = length(List.flatten(header_lines))
    placeholder_lines = format_input_placeholder(log_view, columns)
    chrome_lines = 2 + length(metadata_lines) + length(placeholder_lines) + 1
    # chrome: pane header + spacer + metadata + placeholder + closing border

    pane_budget = rows - header_height - chrome_lines

    if pane_budget < @min_log_pane_lines do
      # Graceful degrade — too small to render a useful pane; fall back to list tail.
      format_view_tail(:list, header_lines, running, retrying, columns, rows)
      |> case do
        {tail, _} -> {tail, total_lines}
      end
    else
      pane_lines = slice_log_lines(log_lines, pane_budget, log_view.scroll)
      pane_title = format_pane_title(log_view, running)

      tail =
        [
          colorize("├─ #{pane_title}", @ansi_bold),
          "│"
        ] ++
          metadata_lines ++
          pane_lines ++
          [closing_border_or_separator()] ++
          placeholder_lines ++
          [closing_border()]

      {tail, total_lines}
    end
  end

  defp format_log_metadata(log_view, running, _columns) do
    entry = running_entry_for_identifier(running, log_view.issue_identifier)
    title = log_view.title || (entry && Map.get(entry, :title)) || "—"

    metadata_line =
      case entry do
        nil ->
          colorize("│   ", @ansi_gray) <>
            colorize("PID: ", @ansi_bold) <>
            colorize("(finished)", @ansi_gray) <>
            colorize(" | ", @ansi_gray) <>
            colorize("Tokens: ", @ansi_bold) <>
            colorize("(finished)", @ansi_gray)

        _ ->
          tokens = Map.get(entry, :agent_total_tokens, 0)
          pid = Map.get(entry, :codex_app_server_pid) || "n/a"

          colorize("│   ", @ansi_gray) <>
            colorize("PID: ", @ansi_bold) <>
            colorize(to_string(pid), @ansi_yellow) <>
            colorize(" | ", @ansi_gray) <>
            colorize("Tokens: ", @ansi_bold) <>
            colorize(format_count(tokens), @ansi_yellow)
      end

    issue_line =
      colorize("│   ", @ansi_gray) <>
        colorize("Issue: ", @ansi_bold) <>
        colorize(title || "—", @ansi_cyan)

    [metadata_line, issue_line, "│"]
  end

  defp closing_border_or_separator, do: "│"

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
      {"user", "Operator message"} -> operator_style()
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
    state_part =
      case running_entry_for_identifier(running, id) do
        nil -> " (finished)"
        entry -> " (#{entry.state})"
      end

    case log_view.workspace_path do
      nil -> "Agent log: #{id}#{state_part} — no local workspace"
      _ -> "Agent log: #{id}#{state_part}"
    end
  end

  defp running_entry_for_identifier(running, id) do
    Enum.find(running, &(to_string(&1.identifier) == to_string(id)))
  end

  defp format_input_placeholder(log_view, columns) do
    inner_width = max(20, columns - 4)
    composer = Map.get(log_view, :composer, fresh_composer())
    buffer = if composer.buffer == "", do: "", else: composer.buffer
    prompt = if buffer == "", do: ">", else: "> " <> buffer
    prompt_lines = prompt |> String.split("\n", trim: false) |> Enum.flat_map(&wrap_line(&1, inner_width))

    status =
      cond do
        is_binary(composer.last_error) ->
          {"error: #{composer.last_error}", @ansi_red}

        is_integer(composer.pending_request_id) ->
          {"sent; waiting for agent turn", @ansi_yellow}

        Map.get(log_view, :mode, :typing) == :browsing ->
          {"Tab returns to chat · J/K move agents · Space opens selected log · Esc closes log · Ctrl-C pauses", @ansi_gray}

        true ->
          {"Enter sends · Esc closes log · Ctrl-C pauses · Alt-Enter newline", @ansi_gray}
      end

    Enum.map(prompt_lines, &("│ " <> colorize(&1, @ansi_white))) ++
      ["│ " <> colorize(elem(status, 0), elem(status, 1))]
  end

  @left_pane_visible_width 56

  # credo:disable-for-next-line
  defp format_two_pane_header(
         agent_count,
         max_agents,
         tps,
         agent_seconds_running,
         agent_input_tokens,
         agent_output_tokens,
         agent_total_tokens,
         rate_limits,
         polling,
         columns
       ) do
    left_lines = [
      colorize("│ ITS: ", @ansi_bold) <>
        colorize(Config.tracker_kind(), @ansi_cyan) <>
        colorize(" | ", @ansi_gray) <>
        colorize("Agent: ", @ansi_bold) <>
        colorize(Config.agent_kind(), @ansi_cyan),
      colorize("│ Agents: ", @ansi_bold) <>
        colorize("#{agent_count}", @ansi_green) <>
        colorize("/", @ansi_gray) <>
        colorize("#{max_agents}", @ansi_gray),
      colorize("│ Throughput: ", @ansi_bold) <> colorize("#{format_tps(tps)} tps", @ansi_cyan),
      colorize("│ Runtime: ", @ansi_bold) <>
        colorize(format_runtime_seconds(agent_seconds_running), @ansi_magenta),
      colorize("│ Tokens: ", @ansi_bold) <>
        colorize("in #{format_count(agent_input_tokens)}", @ansi_yellow) <>
        colorize(" | ", @ansi_gray) <>
        colorize("out #{format_count(agent_output_tokens)}", @ansi_yellow) <>
        colorize(" | ", @ansi_gray) <>
        colorize("total #{format_count(agent_total_tokens)}", @ansi_yellow)
    ]

    right_lines =
      [colorize("Rate Limits: ", @ansi_bold) <> format_rate_limits(rate_limits)] ++
        right_project_lines() ++
        [right_refresh_line(polling)]

    rows = pair_pane_lines(left_lines, right_lines)
    [format_title_row(columns) | rows]
  end

  defp format_title_row(columns) do
    title = colorize("╭─ SYMPHONY STATUS", @ansi_bold)

    case dashboard_url() do
      url when is_binary(url) ->
        link = colorize(url, @ansi_cyan)
        title_visible = visible_length(title)
        link_visible = visible_length(link)
        # Reserve at least one space between title and link.
        gap = max(1, columns - title_visible - link_visible)
        title <> String.duplicate(" ", gap) <> link

      _ ->
        title
    end
  end

  defp pair_pane_lines(left_lines, right_lines) do
    count = max(length(left_lines), length(right_lines))

    Enum.map(0..(count - 1), fn i ->
      left = Enum.at(left_lines, i) || "│"
      right = Enum.at(right_lines, i) || ""

      "#{pad_visible(left, @left_pane_visible_width)} #{colorize("│", @ansi_gray)} #{right}"
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

  defp render_to_terminal(content) do
    IO.write([
      IO.ANSI.home(),
      IO.ANSI.clear(),
      normalize_status_lines(content),
      "\n"
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

    {content, _log_total_lines} = format_snapshot_content(snapshot_data, tps, Keyword.merge(base, opts))
    content
  end

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

  defp format_runtime_and_turns(seconds, turn_count) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(seconds)} / #{turn_count}"
  end

  defp format_runtime_and_turns(seconds, _turn_count), do: format_runtime_seconds(seconds)

  defp format_count(nil), do: "0"

  defp format_count(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> group_thousands()
  end

  defp format_count(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {number, ""} -> group_thousands(Integer.to_string(number))
      _ -> value
    end
  end

  defp format_count(value), do: to_string(value)

  defp running_table_header_row do
    header =
      [
        format_cell("ID", @running_id_width),
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
        @running_state_width +
        @running_issue_width +
        @running_age_width + 2

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

  defp format_rate_limits(nil), do: colorize("unavailable", @ansi_gray)

  defp format_rate_limits(rate_limits) when is_map(rate_limits) do
    limit_id =
      map_value(rate_limits, ["limit_id", :limit_id, "limit_name", :limit_name]) ||
        "unknown"

    primary = format_rate_limit_bucket(map_value(rate_limits, ["primary", :primary]))
    secondary = format_rate_limit_bucket(map_value(rate_limits, ["secondary", :secondary]))
    credits = format_rate_limit_credits(map_value(rate_limits, ["credits", :credits]))

    colorize(to_string(limit_id), @ansi_yellow) <>
      colorize(" | ", @ansi_gray) <>
      colorize("primary #{primary}", @ansi_cyan) <>
      colorize(" | ", @ansi_gray) <>
      colorize("secondary #{secondary}", @ansi_cyan) <>
      colorize(" | ", @ansi_gray) <>
      colorize(credits, @ansi_green)
  end

  defp format_rate_limits(other) do
    other
    |> inspect(limit: 10)
    |> truncate(80)
    |> colorize(@ansi_gray)
  end

  defp format_rate_limit_bucket(nil), do: "n/a"

  defp format_rate_limit_bucket(bucket) when is_map(bucket) do
    remaining = map_value(bucket, ["remaining", :remaining])
    limit = map_value(bucket, ["limit", :limit])

    reset_value =
      map_value(bucket, [
        "reset_in_seconds",
        :reset_in_seconds,
        "resetInSeconds",
        :resetInSeconds,
        "reset_at",
        :reset_at,
        "resetAt",
        :resetAt,
        "resets_at",
        :resets_at,
        "resetsAt",
        :resetsAt
      ])

    base =
      cond do
        integer_like?(remaining) and integer_like?(limit) ->
          "#{format_count(remaining)}/#{format_count(limit)}"

        integer_like?(remaining) ->
          "remaining #{format_count(remaining)}"

        integer_like?(limit) ->
          "limit #{format_count(limit)}"

        map_size(bucket) == 0 ->
          "n/a"

        true ->
          bucket |> inspect(limit: 6) |> truncate(40)
      end

    if is_nil(reset_value) do
      base
    else
      "#{base} reset #{format_reset_value(reset_value)}"
    end
  end

  defp format_rate_limit_bucket(other), do: to_string(other)

  defp format_rate_limit_credits(nil), do: "credits n/a"

  defp format_rate_limit_credits(credits) when is_map(credits) do
    unlimited = map_value(credits, ["unlimited", :unlimited]) == true
    has_credits = map_value(credits, ["has_credits", :has_credits]) == true
    balance = map_value(credits, ["balance", :balance])

    cond do
      unlimited ->
        "credits unlimited"

      has_credits and is_number(balance) ->
        "credits #{format_number(balance)}"

      has_credits ->
        "credits available"

      true ->
        "credits none"
    end
  end

  defp format_rate_limit_credits(other), do: "credits #{to_string(other)}"

  defp format_reset_value(value) when is_integer(value), do: "#{format_count(value)}s"
  defp format_reset_value(value) when is_binary(value), do: value
  defp format_reset_value(value), do: to_string(value)

  defp format_number(value) when is_integer(value), do: format_count(value)

  defp format_number(value) when is_float(value) do
    value
    |> Float.round(2)
    |> :erlang.float_to_binary(decimals: 2)
  end

  defp map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp map_value(_map, _keys), do: nil

  defp integer_like?(value) when is_integer(value), do: true
  defp integer_like?(_value), do: false

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
          | workspace_path: Map.get(running_entry, :workspace_path, log_view.workspace_path),
            title: Map.get(running_entry, :title, log_view.title),
            composer: reconcile_composer_with_running_entry(log_view.composer, running_entry)
        }

        Map.put(state, :view, {:log, reconciled_log_view})
    end
  end

  defp reconcile_log_view_with_snapshot(state, _snapshot_data), do: state

  defp fresh_composer do
    %{buffer: "", pending_request_id: nil, last_error: nil}
  end

  defp reconcile_composer_with_running_entry(%{pending_request_id: request_id} = composer, running_entry)
       when is_integer(request_id) do
    state = Map.get(running_entry, :work_state) || get_in(running_entry, [:control, :status]) || :working

    if state in [:paused, "paused"] do
      %{composer | pending_request_id: nil}
    else
      composer
    end
  end

  defp reconcile_composer_with_running_entry(composer, _running_entry), do: composer

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
