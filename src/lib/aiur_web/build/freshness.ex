defmodule AiurWeb.Build.Freshness do
  @moduledoc """
  Maps store freshness to payload v1 without inventing observation times.

  The heartbeat is the data's timestamp; observed_at is the server read time.

  | Snapshot result | Daemon state |
  | --- | --- |
  | Current with valid timestamp | live |
  | Stale, orchestrator unavailable | offline |
  | Other stale with valid timestamp | stale |
  | Orchestrator unavailable, no snapshot | offline, no heartbeat |
  | Unpublished, invalid result or timestamp | unknown, no heartbeat |

  | Source input | Source state |
  | --- | --- |
  | Usable healthy provider or current snapshot | ok |
  | Partial healthy provider | incomplete |
  | Stale provider or snapshot | stale |
  | Unavailable/invalid provider, missing snapshot or unknown input | unavailable |
  | Explicitly disabled | disabled |
  """
  alias Aiur.BuildOrder.SourceFreshness
  alias Aiur.{Orchestrator, PollCadence}
  alias AiurWeb.Endpoint

  @spec daemon(term(), integer()) :: map()
  def daemon({status, _, md}, now_ms) when status in [:current, :stale] and is_map(md) do
    heartbeat = SourceFreshness.ms(Map.get(md, :observed_at))
    state = if heartbeat, do: daemon_state(status, Map.get(md, :reason)), else: "unknown"
    %{state: state, heartbeat_at: heartbeat, observed_at: now_ms}
  end

  def daemon(:orchestrator_unavailable, now_ms), do: %{state: "offline", heartbeat_at: nil, observed_at: now_ms}
  def daemon(_, now_ms), do: %{state: "unknown", heartbeat_at: nil, observed_at: now_ms}

  @spec read_daemon(keyword()) :: map()
  def read_daemon(opts \\ []) do
    orchestrator = Keyword.get_lazy(opts, :orchestrator, fn -> Endpoint.config(:orchestrator) || Orchestrator end)
    timeout = Keyword.get_lazy(opts, :timeout, fn -> PollCadence.snapshot_tolerance_ms(Endpoint.config(:snapshot_timeout_ms) || 15_000, class: :dispatch) end)
    daemon(Orchestrator.dashboard_snapshot(orchestrator, timeout), System.os_time(:millisecond))
  end

  @spec push_daemon?(term(), map()) :: boolean()
  def push_daemon?(%{state: state} = old, %{state: state} = new),
    do: state != "live" and Map.get(old, :heartbeat_at) != Map.get(new, :heartbeat_at)

  def push_daemon?(_, _), do: true

  @spec source(term()) :: map()
  defdelegate source(input), to: Aiur.BuildOrder.SourceFreshness

  defp daemon_state(:current, _), do: "live"
  defp daemon_state(:stale, :orchestrator_unavailable), do: "offline"
  defp daemon_state(:stale, _), do: "stale"
end
