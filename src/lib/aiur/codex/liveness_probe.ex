defmodule Aiur.Codex.LivenessProbe do
  @moduledoc """
  Periodically confirms that a quiet Codex turn's app-server still answers RPC.

  A successful rate-limit read is transport liveness evidence, regardless of
  whether the account has quota remaining. An exhausted snapshot is classified
  as the existing usage-limit pause. A timed-out read is a recoverable session
  failure so the runner restores delivered work before replacing the session.
  """

  alias Aiur.AppServer.Rpc
  alias Aiur.Codex.{ExhaustedReset, Frames}
  alias Aiur.Codex.NotificationPolicy

  @probe_interval_ms 60_000

  @doc false
  @spec interval_ms() :: pos_integer()
  def interval_ms, do: @probe_interval_ms

  @doc false
  @spec schedule(map()) :: map()
  def schedule(state) do
    timer = Process.send_after(self(), :codex_liveness_probe, @probe_interval_ms)
    Map.put(state, :liveness_probe_timer, timer)
  end

  @doc false
  @spec run(map(), map()) :: {:continue, map()} | {:paused, map()} | {:error, term()}
  def run(session, state) do
    now = Map.get(session, :clock, &DateTime.utc_now/0).()

    case {usage_limit_reset(session, now), Map.get(state, :liveness_probe_pending?, false)} do
      {%DateTime{} = reset, _pending?} ->
        {:paused, %{kind: :usage_limit_exhausted, reason: "Codex usage limit is exhausted", reset_at: DateTime.to_iso8601(reset)}}

      {nil, true} ->
        classify_timeout(session, state)

      {nil, false} ->
        request_rate_limits(session, state)
    end
  end

  @doc false
  @spec handle_response(map(), map(), map()) :: {:continue, map()} | {:paused, map()} | {:error, term()}
  def handle_response(session, state, %{"error" => error}) do
    now = Map.get(session, :clock, &DateTime.utc_now/0).()

    if NotificationPolicy.usage_limit_exceeded?(error) do
      case usage_limit_reset(session, now) do
        %DateTime{} = reset ->
          {:paused, %{kind: :usage_limit_exhausted, reason: "Codex rate-limit read reported usage exhaustion", reset_at: DateTime.to_iso8601(reset)}}

        nil ->
          {:paused, %{kind: :usage_limit_exhausted, reason: "Codex rate-limit read reported usage exhaustion", reset_hint: nil}}
      end
    else
      {:error, {:liveness_probe_failed, {:response_error, error}, state}}
    end
  end

  def handle_response(session, state, %{"rateLimits" => rate_limits} = response) when is_map(rate_limits) do
    ExhaustedReset.observe_snapshot(session, response)

    case usage_limit_reset(session, Map.get(session, :clock, &DateTime.utc_now/0).()) do
      %DateTime{} = reset ->
        {:paused,
         %{
           kind: :usage_limit_exhausted,
           reason: "Codex account rate-limit snapshot is exhausted",
           reset_at: DateTime.to_iso8601(reset)
         }}

      nil ->
        {:continue, schedule(state)}
    end
  end

  def handle_response(_session, state, _response), do: {:error, {:liveness_probe_failed, :invalid_response, state}}

  @doc false
  @spec request_rate_limits(map(), map()) :: {:continue, map()} | {:error, term()}
  def request_rate_limits(session, state) do
    frame = Frames.liveness_rate_limits_read_frame()

    case Rpc.send_line(session.port, frame) do
      true ->
        timer = Process.send_after(self(), :codex_liveness_probe, probe_timeout_ms())
        {:continue, state |> Map.put(:liveness_probe_pending?, true) |> Map.put(:liveness_probe_timer, timer)}
    end
  rescue
    ArgumentError -> {:error, {:liveness_probe_failed, :port_closed}}
  end

  @doc false
  @spec timeout(map(), map()) :: {:paused, map()} | {:error, term()}
  def timeout(session, state), do: classify_timeout(session, state)

  @doc false
  @spec probe_timeout_ms() :: pos_integer()
  def probe_timeout_ms, do: max(1_000, min(Aiur.Config.agent_read_timeout_ms(), 10_000))

  defp classify_timeout(session, state) do
    now = Map.get(session, :clock, &DateTime.utc_now/0).()

    case usage_limit_reset(session, now) do
      %DateTime{} = reset ->
        {:paused, %{kind: :usage_limit_exhausted, reason: "Codex usage limit was exhausted before app-server became silent", reset_at: DateTime.to_iso8601(reset)}}

      nil ->
        {:error, {:response_timeout, :codex_liveness_probe, state}}
    end
  end

  defp usage_limit_reset(session, now) do
    with %DateTime{} = reset <- ExhaustedReset.latest(session, now),
         true <- DateTime.diff(reset, now, :second) <= 86_400 do
      reset
    else
      _ -> nil
    end
  end
end
