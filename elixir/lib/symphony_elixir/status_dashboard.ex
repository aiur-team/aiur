defmodule SymphonyElixir.StatusDashboard do
  @moduledoc """
  Renders a status snapshot for orchestrator and worker activity as a terminal UI.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, HttpServer, Tracker}
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.ObservabilityPubSub

  @minimum_idle_rerender_ms 1_000
  @throughput_window_ms 5_000
  @throughput_graph_window_ms 10 * 60 * 1000
  @throughput_graph_columns 24
  @sparkline_blocks ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
  @running_id_width 8
  @running_stage_width 14
  @running_pid_width 8
  @running_age_width 12
  @running_tokens_width 10
  @running_session_width 14
  @running_event_default_width 44
  @running_event_min_width 12
  @running_row_chrome_width 10
  @default_terminal_columns 115

  @ansi_reset IO.ANSI.reset()
  @ansi_bold IO.ANSI.bright()
  @ansi_blue IO.ANSI.blue()
  @ansi_cyan IO.ANSI.cyan()
  @ansi_dim IO.ANSI.faint()
  @ansi_green IO.ANSI.green()
  @ansi_red IO.ANSI.red()
  @ansi_orange IO.ANSI.yellow()
  @ansi_yellow IO.ANSI.yellow()
  @ansi_magenta IO.ANSI.magenta()
  @ansi_gray IO.ANSI.light_black()

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
    :last_snapshot_fingerprint
  ]

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
          last_snapshot_fingerprint: term() | nil
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

  @spec init(keyword()) :: {:ok, t()}
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
       last_snapshot_fingerprint: nil
     }}
  end

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

  @spec handle_info(term(), t()) :: {:noreply, t()}
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
    state = Map.put(state, :token_samples, token_samples)

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

    if snapshot_data != state.last_snapshot_fingerprint or periodic_rerender_due?(state, now_ms) do
      content =
        format_snapshot_content(
          snapshot_data,
          tps
        )

      state
      |> maybe_update_snapshot_fingerprint(snapshot_data)
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
    case snapshot_payload() do
      {:ok, %{running: running, retrying: retrying, agent_totals: agent_totals} = snapshot} ->
        total_tokens = Map.get(agent_totals, :total_tokens, 0)

        {
          {:ok,
           %{
             running: running,
             retrying: retrying,
             agent_totals: agent_totals,
             rate_limits: Map.get(snapshot, :rate_limits),
             polling: Map.get(snapshot, :polling)
           }},
          update_token_samples(token_samples, now_ms, total_tokens)
        }

      :error ->
        {
          :error,
          prune_samples(token_samples, now_ms)
        }
    end
  end

  defp format_snapshot_content(snapshot_data, tps, terminal_columns_override \\ nil) do
    case snapshot_data do
      {:ok, %{running: running, retrying: retrying, agent_totals: agent_totals} = snapshot} ->
        rate_limits = Map.get(snapshot, :rate_limits)
        project_link_lines = format_project_link_lines()
        project_refresh_line = format_project_refresh_line(Map.get(snapshot, :polling))
        agent_input_tokens = Map.get(agent_totals, :input_tokens, 0)
        agent_output_tokens = Map.get(agent_totals, :output_tokens, 0)
        agent_total_tokens = Map.get(agent_totals, :total_tokens, 0)
        agent_seconds_running = Map.get(agent_totals, :seconds_running, 0)
        agent_count = length(running)
        max_agents = Config.max_concurrent_agents()
        running_event_width = running_event_width(terminal_columns_override)
        running_rows = format_running_rows(running, running_event_width)
        running_to_backoff_spacer = if(running == [], do: [], else: ["│"])
        backoff_rows = format_retry_rows(retrying)

        ([
           colorize("╭─ SYMPHONY STATUS", @ansi_bold),
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
             colorize("total #{format_count(agent_total_tokens)}", @ansi_yellow),
           colorize("│ Rate Limits: ", @ansi_bold) <> format_rate_limits(rate_limits),
           project_link_lines,
           project_refresh_line,
           colorize("├─ Running", @ansi_bold),
           "│",
           running_table_header_row(running_event_width),
           running_table_separator_row(running_event_width)
         ] ++
           running_rows ++
           running_to_backoff_spacer ++
           [colorize("├─ Backoff queue", @ansi_bold), "│"] ++
           backoff_rows ++
           [closing_border()])
        |> List.flatten()
        |> Enum.join("\n")

      :error ->
        [
          colorize("╭─ SYMPHONY STATUS", @ansi_bold),
          colorize("│ Orchestrator snapshot unavailable", @ansi_red),
          colorize("│ Throughput: ", @ansi_bold) <> colorize("#{format_tps(tps)} tps", @ansi_cyan),
          format_project_link_lines(),
          format_project_refresh_line(nil),
          closing_border()
        ]
        |> List.flatten()
        |> Enum.join("\n")
    end
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
        colorize(project_url(Config.tracker_kind(), identity), @ansi_cyan)

      _ ->
        colorize("n/a", @ansi_gray)
    end
  end

  defp project_url("github", repo), do: "https://github.com/#{repo}/issues"
  defp project_url(_, slug), do: "https://linear.app/project/#{slug}/issues"

  defp format_project_refresh_line(%{checking?: true}) do
    colorize("│ Next refresh: ", @ansi_bold) <> colorize("checking now…", @ansi_cyan)
  end

  defp format_project_refresh_line(%{next_poll_in_ms: due_in_ms}) when is_integer(due_in_ms) do
    due_in_ms = max(due_in_ms, 0)
    seconds = div(due_in_ms + 999, 1000)
    colorize("│ Next refresh: ", @ansi_bold) <> colorize("#{seconds}s", @ansi_cyan)
  end

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
  @spec format_snapshot_content_for_test(term(), number()) :: String.t()
  def format_snapshot_content_for_test(snapshot_data, tps), do: format_snapshot_content(snapshot_data, tps)

  @doc false
  @spec format_snapshot_content_for_test(term(), number(), integer() | nil) :: String.t()
  def format_snapshot_content_for_test(snapshot_data, tps, terminal_columns),
    do: format_snapshot_content(snapshot_data, tps, terminal_columns)

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

  defp format_running_rows(running, running_event_width) do
    if running == [] do
      [
        "│  " <> colorize("No active agents", @ansi_gray),
        "│"
      ]
    else
      running
      |> Enum.sort_by(& &1.identifier)
      |> Enum.map(&format_running_summary(&1, running_event_width))
    end
  end

  # credo:disable-for-next-line
  defp format_running_summary(running_entry, running_event_width) do
    issue = format_cell(running_entry.identifier || "unknown", @running_id_width)
    state = running_entry.state || "unknown"
    state_display = format_cell(to_string(state), @running_stage_width)
    session = running_entry.session_id |> compact_session_id() |> format_cell(@running_session_width)
    pid = format_cell(running_entry.codex_app_server_pid || "n/a", @running_pid_width)
    total_tokens = running_entry.agent_total_tokens || 0
    runtime_seconds = running_entry.runtime_seconds || 0
    turn_count = Map.get(running_entry, :turn_count, 0)
    age = format_cell(format_runtime_and_turns(runtime_seconds, turn_count), @running_age_width)
    event = running_entry.last_codex_event || "none"
    event_label = format_cell(summarize_message(running_entry.last_codex_message), running_event_width)

    tokens = format_count(total_tokens) |> format_cell(@running_tokens_width, :right)

    status_color =
      case event do
        :none -> @ansi_red
        "codex/event/token_count" -> @ansi_yellow
        "codex/event/task_started" -> @ansi_green
        "turn_completed" -> @ansi_magenta
        _ -> @ansi_blue
      end

    [
      "│ ",
      status_dot(status_color),
      " ",
      colorize(issue, @ansi_cyan),
      " ",
      colorize(state_display, status_color),
      " ",
      colorize(pid, @ansi_yellow),
      " ",
      colorize(age, @ansi_magenta),
      " ",
      colorize(tokens, @ansi_yellow),
      " ",
      colorize(session, @ansi_cyan),
      " ",
      colorize(event_label, status_color)
    ]
    |> Enum.join("")
  end

  @doc false
  @spec format_running_summary_for_test(map(), integer() | nil) :: String.t()
  def format_running_summary_for_test(running_entry, terminal_columns \\ nil),
    do: format_running_summary(running_entry, running_event_width(terminal_columns))

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

  defp running_table_header_row(running_event_width) do
    header =
      [
        format_cell("ID", @running_id_width),
        format_cell("STAGE", @running_stage_width),
        format_cell("PID", @running_pid_width),
        format_cell("AGE / TURN", @running_age_width),
        format_cell("TOKENS", @running_tokens_width),
        format_cell("SESSION", @running_session_width),
        format_cell("EVENT", running_event_width)
      ]
      |> Enum.join(" ")

    "│   " <> colorize(header, @ansi_gray)
  end

  defp running_table_separator_row(running_event_width) do
    separator_width =
      @running_id_width +
        @running_stage_width +
        @running_pid_width +
        @running_age_width +
        @running_tokens_width +
        @running_session_width +
        running_event_width + 6

    "│   " <> colorize(String.duplicate("─", separator_width), @ansi_gray)
  end

  defp running_event_width(terminal_columns) do
    terminal_columns = terminal_columns || terminal_columns()

    max(
      @running_event_min_width,
      terminal_columns - fixed_running_width() - @running_row_chrome_width
    )
  end

  defp fixed_running_width do
    @running_id_width +
      @running_stage_width +
      @running_pid_width +
      @running_age_width +
      @running_tokens_width +
      @running_session_width
  end

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
        fixed_running_width() + @running_row_chrome_width + @running_event_default_width

      value ->
        case Integer.parse(String.trim(value)) do
          {columns, ""} when columns > 0 -> columns
          _ -> @default_terminal_columns
        end
    end
  end

  defp format_cell(value, width, align \\ :left) do
    value =
      value
      |> to_string()
      |> String.replace("\n", " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> truncate_plain(width)

    case align do
      :right -> String.pad_leading(value, width)
      _ -> String.pad_trailing(value, width)
    end
  end

  defp truncate_plain(value, width) do
    if byte_size(value) <= width do
      value
    else
      String.slice(value, 0, width - 3) <> "..."
    end
  end

  defp compact_session_id(nil), do: "n/a"
  defp compact_session_id(session_id) when not is_binary(session_id), do: "n/a"

  defp compact_session_id(session_id) do
    if String.length(session_id) > 10 do
      String.slice(session_id, 0, 4) <> "..." <> String.slice(session_id, -6, 6)
    else
      session_id
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

  defp status_dot(color_code) do
    colorize("●", color_code)
  end

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

  defp summarize_message(message), do: humanize_codex_message(message)

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
