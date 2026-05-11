defmodule SymphonyElixir.TUI.Widgets.StatusScreen do
  @moduledoc false

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias SymphonyElixir.{Config, HttpServer, StatusDashboard, Tracker}
  alias SymphonyElixir.TUI.State

  @running_event_width 44

  @spec render(State.t(), ExRatatui.Frame.t()) :: [{Paragraph.t(), Rect.t()}]
  def render(%State{} = state, frame) do
    state
    |> render_rows()
    |> Enum.take(frame.height)
    |> Enum.with_index()
    |> Enum.map(fn {row, y} ->
      {%Paragraph{text: row, wrap: false}, %Rect{x: 0, y: y, width: frame.width, height: 1}}
    end)
  end

  @spec render_text(State.t()) :: String.t()
  def render_text(%State{} = state) do
    state
    |> render_rows()
    |> Enum.join("\n")
  end

  defp render_rows(%State{snapshot: {:ok, snapshot}} = state) do
    running = Map.get(snapshot, :running, [])
    retrying = Map.get(snapshot, :retrying, [])
    agent_totals = Map.get(snapshot, :agent_totals, %{})

    [
      "╭─ SYMPHONY STATUS",
      "│ ITS: #{Config.tracker_kind()} | Agent: #{Config.agent_kind()}",
      "│ Agents: #{length(running)}/#{Config.max_concurrent_agents()}",
      "│ Throughput: 0 tps",
      "│ Runtime: #{format_runtime_seconds(Map.get(agent_totals, :seconds_running, 0))}",
      "│ Tokens: in #{format_count(Map.get(agent_totals, :input_tokens, 0))} | out #{format_count(Map.get(agent_totals, :output_tokens, 0))} | total #{format_count(Map.get(agent_totals, :total_tokens, 0))}",
      "│ Rate Limits: unavailable",
      "│ Project: #{project_label()}",
      dashboard_line(),
      "│ Next refresh: #{refresh_label(Map.get(snapshot, :polling))}",
      "├─ Running",
      "│",
      running_table_header_row(),
      running_table_separator_row(),
      running_rows(running, state.selected_index),
      if(running == [], do: [], else: ["│"]),
      "├─ Backoff queue",
      "│",
      retry_rows(retrying),
      "╰─"
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp render_rows(%State{}) do
    [
      "╭─ SYMPHONY STATUS",
      "│ Orchestrator snapshot unavailable",
      "│ Throughput: 0 tps",
      "│ Project: #{project_label()}",
      dashboard_line(),
      "│ Next refresh: n/a",
      "╰─"
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp running_rows([], _selected_index), do: ["│  No active agents", "│"]

  defp running_rows(running, selected_index) do
    running
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} ->
      selected? = index == selected_index
      marker = if selected?, do: "●", else: " "

      "│ #{marker} " <>
        pad(truncate(to_string(Map.get(entry, :identifier, "n/a")), 8), 8) <>
        " " <>
        pad(truncate(to_string(Map.get(entry, :state, "n/a")), 14), 14) <>
        " " <>
        pad(truncate(to_string(Map.get(entry, :codex_app_server_pid, "n/a")), 8), 8) <>
        " " <>
        pad(format_age(entry), 12) <>
        " " <>
        pad(format_count(Map.get(entry, :agent_total_tokens, 0)), 10) <>
        " " <>
        pad(truncate(to_string(Map.get(entry, :session_id, "n/a")), 14), 14) <>
        " " <>
        truncate(event_summary(entry), @running_event_width)
    end)
  end

  defp retry_rows([]), do: ["│  No queued retries"]

  defp retry_rows(retrying) do
    Enum.map(retrying, fn entry ->
      "│  #{Map.get(entry, :identifier, "n/a")} attempt=#{Map.get(entry, :attempt, 0)} due=#{format_due_in(Map.get(entry, :due_in_ms))} error=#{sanitize(Map.get(entry, :error, "retry scheduled"))}"
    end)
  end

  defp running_table_header_row do
    "│   " <>
      pad("ID", 8) <>
      " " <>
      pad("STAGE", 14) <>
      " " <>
      pad("PID", 8) <>
      " " <>
      pad("AGE / TURN", 12) <>
      " " <>
      pad("TOKENS", 10) <>
      " " <>
      pad("SESSION", 14) <>
      " EVENT"
  end

  defp running_table_separator_row do
    "│   " <> String.duplicate("─", 8 + 1 + 14 + 1 + 8 + 1 + 12 + 1 + 10 + 1 + 14 + 1 + @running_event_width)
  end

  defp project_label do
    case Tracker.project_identity() do
      identity when is_binary(identity) and identity != "" -> identity
      _ -> "n/a"
    end
  end

  defp dashboard_line do
    case dashboard_url() do
      nil -> nil
      url -> "│ Dashboard: #{url}"
    end
  end

  defp dashboard_url do
    case Config.server_port() do
      port when is_integer(port) and port > 0 ->
        "http://#{dashboard_url_host(Config.server_host())}:#{HttpServer.bound_port() || port}/"

      _ ->
        nil
    end
  end

  defp dashboard_url_host(host) when host in ["0.0.0.0", "::", "[::]", ""], do: "127.0.0.1"
  defp dashboard_url_host(host) when is_binary(host), do: host
  defp dashboard_url_host(_host), do: "127.0.0.1"

  defp refresh_label(%{checking?: true}), do: "checking now…"

  defp refresh_label(%{next_poll_in_ms: due_in_ms}) when is_integer(due_in_ms) do
    "#{div(max(due_in_ms, 0) + 999, 1_000)}s"
  end

  defp refresh_label(_polling), do: "n/a"

  defp event_summary(%{last_codex_message: message}), do: StatusDashboard.humanize_codex_message(message)
  defp event_summary(_entry), do: "n/a"

  defp format_age(entry) do
    runtime = Map.get(entry, :runtime_seconds, 0)
    turn_count = Map.get(entry, :turn_count, 0)
    "#{format_runtime_seconds(runtime)} / #{turn_count}"
  end

  defp format_runtime_seconds(seconds) when is_integer(seconds) and seconds >= 3_600 do
    "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
  end

  defp format_runtime_seconds(seconds) when is_integer(seconds) and seconds >= 60 do
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp format_runtime_seconds(seconds) when is_integer(seconds), do: "#{max(seconds, 0)}s"
  defp format_runtime_seconds(_seconds), do: "0s"

  defp format_count(count) when is_integer(count) do
    count
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(",", &Enum.join/1)
  end

  defp format_count(_count), do: "0"

  defp format_due_in(due_in_ms) when is_integer(due_in_ms), do: "#{div(max(due_in_ms, 0) + 999, 1_000)}s"
  defp format_due_in(_due_in_ms), do: "n/a"

  defp sanitize(value) do
    value
    |> to_string()
    |> String.replace(~r/\\n|\r|\n/, " ")
    |> String.trim()
  end

  defp pad(value, width), do: String.pad_trailing(value, width)

  defp truncate(value, max) when byte_size(value) > max do
    value |> String.slice(0, max) |> Kernel.<>("...")
  end

  defp truncate(value, _max), do: value
end
