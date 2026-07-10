defmodule Aiur.AgentList.RenderState do
  @moduledoc """
  Builds the explicit renderer input map for AgentList frames.
  """

  alias Aiur.AgentList.Summaries
  alias Aiur.{Config, HttpServer, Tracker}

  @spec build(map()) :: map()
  def build(state) do
    # Re-query geometry on every render: tmux resizes panes after splits and
    # doesn't update COLUMNS/LINES in our env, so the values captured at
    # init/1 go stale.
    {cols, rows} = terminal_geometry()

    state
    |> Map.take([:summaries, :selection_index, :selection_focus, :help_visible?, :max_agents_alert?])
    |> Map.put(:columns, cols)
    |> Map.put(:rows, rows)
    |> Map.put(:project_label, project_label())
    |> Map.put(:dashboard_url, dashboard_url())
    |> Map.put(:agent_kind, agent_kind())
    |> Map.put(:agent_count, Summaries.active_agent_count(state.summaries))
    |> Map.put(:max_agents, max_agents_from_state(state))
    |> Map.put(:visible_sessions, state.visible_sessions)
    |> Map.put(:debug_mode?, Map.get(state, :debug_mode?, false))
    |> Map.put(:perf_summary, Map.get(state, :perf_summary, %{}))
    |> Map.put(:warmth_events, Map.get(state, :warmth_events, []))
    |> Map.put(:debug_events, Map.get(state, :debug_events, []))
    |> Map.put(:attach_state, Map.get(state, :attach_state, %{}))
    |> Map.put(:started_slots, Map.get(state, :started_slots, MapSet.new()))
    |> Map.put(:fully_warmed_slots, Map.get(state, :fully_warmed_slots, MapSet.new()))
    |> Map.put(:opened_panes, Map.get(state, :opened_panes, MapSet.new()))
    |> Map.put(:agents_with_content, Map.get(state, :agents_with_content, MapSet.new()))
    |> Map.put(:latest_event_by_id, Map.get(state, :latest_event_by_id, %{}))
    |> Map.put(:phase_by_identifier, Map.get(state, :phase_by_identifier, %{}))
    |> Map.put(:open_attentions_by_id, Map.get(state, :open_attentions_by_id, %{}))
    |> Map.put(:progress_by_id, Map.get(state, :progress_by_id, %{}))
    |> Map.put(
      :warm_status_dark_mode?,
      Map.get(state, :warm_status_dark_mode?, true)
    )
    |> Map.put(:remote_control_hint, Map.get(state, :remote_control_hint))
    |> Map.put(:prewarm_active?, Map.get(state, :prewarm_active?, false))
    |> Map.put(:prewarm_phase, Map.get(state, :prewarm_phase))
    |> Map.put(:truecolor?, truecolor_supported?())
  end

  @doc false
  @spec safe_call((-> term())) :: term() | nil
  def safe_call(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
    _, _ -> nil
  end

  @doc false
  @spec terminal_geometry() :: {pos_integer(), pos_integer()}
  def terminal_geometry do
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

  defp agent_kind do
    case safe_call(fn -> Config.agent_kind() end) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  # Read from the cached poll_state payload. The orchestrator publishes
  # `max_concurrent_agents` in every `:poll_state_changed` broadcast, so
  # render avoids the 5 s `Orchestrator.max_concurrent_agents/0` GenServer.call
  # that previously froze arrow-key input during poll cycles.
  defp max_agents_from_state(%{poll_state: %{max_concurrent_agents: n}})
       when is_integer(n) and n > 0,
       do: n

  defp max_agents_from_state(_state), do: nil

  # Note: the previous `max_agents/1` private helper called
  # `Orchestrator.max_concurrent_agents` synchronously and blocked the
  # render tick for up to 5 s during poll cycles. It was replaced by
  # `max_agents_from_state/1` (cache + broadcast). Do NOT reintroduce a
  # blocking call here without also updating the broadcast path.

  # 24-bit color support, detected from COLORTERM (set to "truecolor" or
  # "24bit" by modern terminals). Drives the MODEL column's per-model colors:
  # truecolor terminals get the exact website hexes, others the nearest ANSI.
  defp truecolor_supported? do
    System.get_env("COLORTERM") in ["truecolor", "24bit"]
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default
end
