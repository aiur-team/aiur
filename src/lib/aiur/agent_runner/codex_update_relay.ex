defmodule Aiur.AgentRunner.CodexUpdateRelay do
  @moduledoc """
  Decides which normalized backend messages reach `Aiur.Orchestrator`.

  ## Why this exists (#1731)

  Every normalized message used to be forwarded to the orchestrator as
  `{:codex_worker_update, issue_id, message}`. Codex streams assistant text as
  `item/agentMessage/delta` notifications carrying a few characters each, so a
  single talkative agent puts hundreds of messages per second into the
  orchestrator's mailbox — the process that also owns dispatch, capacity and
  every operator query. A live capture showed 9,313 of 10,456 queued messages
  were exactly these deltas. Fleet control was starved by streamed prose.

  ## What a delta is actually worth to the orchestrator

  `Aiur.Orchestrator.TokenAccounting` uses an update for token usage, rate
  limits, session id, app-server pid and turn boundaries — none of which a text
  delta carries. All a delta contributes is `last_codex_timestamp` /
  `last_codex_message`, i.e. the "still alive, still talking" liveness field,
  and it triggers a full dashboard notify each time.

  So: control-bearing messages are forwarded unconditionally and immediately;
  stream-only messages are coalesced to at most one per coalescing interval per
  turn. Liveness still refreshes several times a second, and streaming volume
  can no longer bury a dispatch decision.

  The transcript, event log and live-conversation paths are untouched — they
  have their own subscribers and never went through the orchestrator's mailbox.
  """

  alias Aiur.Orchestrator.TokenAccounting.Payloads

  # One liveness refresh every 250ms is four times a second per running agent:
  # far finer than any stall threshold reads, and a ~99% cut against a stream
  # that produces deltas every few milliseconds.
  @coalesce_interval_ms 250

  @streaming_methods [
    "item/agentMessage/delta",
    "item/reasoning/delta",
    "item/agentReasoning/delta",
    "item/commandOutput/delta",
    "codex/event/agent_message_delta",
    "codex/event/agent_reasoning_delta",
    "codex/event/agent_reasoning_raw_content_delta"
  ]

  @doc """
  Forwards `message` to `recipient` unless it is a stream-only update arriving
  inside the current coalescing window for `issue_id`.

  Returns `:sent` or `:coalesced` so callers (and tests) can observe the
  decision. Window state is process-local: `on_message` callbacks for one turn
  run in one process, and a stale window in a dead process costs nothing.
  """
  @spec relay(pid() | nil, String.t(), map()) :: :sent | :coalesced
  def relay(recipient, issue_id, message),
    do: relay(recipient, issue_id, message, System.monotonic_time(:millisecond))

  @doc false
  @spec relay(pid() | nil, String.t(), map(), integer()) :: :sent | :coalesced
  def relay(recipient, issue_id, message, now_ms) when is_binary(issue_id) do
    if forward?(issue_id, message, now_ms) do
      if is_pid(recipient), do: send(recipient, {:codex_worker_update, issue_id, message})
      :sent
    else
      :coalesced
    end
  end

  def relay(_recipient, _issue_id, _message, _now_ms), do: :coalesced

  @doc """
  True when the message carries something the orchestrator's accounting acts on.

  Deliberately conservative: anything that is not recognisably a pure text/
  reasoning delta counts as control and is forwarded. A message that also
  carries usage, rate limits or a session id is control even if its method is a
  delta method, so a backend that starts attaching usage to deltas cannot
  silently lose it.

  That last promise is only worth as much as the shapes it recognises, so it is
  the *union* of two tests, not either one alone:

    * `Payloads` — the exact extractors `Aiur.Orchestrator.TokenAccounting`
      runs on the other end. Anything the orchestrator would actually bill is
      control by construction, including the nested `params.msg.info` and
      `params.tokenUsage` envelopes a hand-rolled key check misses. That
      `params.msg` envelope is exactly the shape the `codex/event/*` methods
      below use.
    * a plain presence check on top-level `usage` / `rate_limits` / session id,
      in either key form. `Payloads` is deliberately strict — it ignores a bare
      `usage` map that sits at no path it recognises — and this path must not
      inherit that strictness. Forwarding a message the orchestrator turns out
      to ignore costs one mailbox slot; coalescing one it would have billed
      loses the number for good.

  `codex_app_server_pid` is intentionally *not* part of the test even though
  every app-server message carries it: it is the same constant for the whole
  turn, the orchestrator's write of it is idempotent, and the turn's first
  (control) message already establishes it. Including it would classify every
  message as control and coalesce nothing.
  """
  @spec control?(map()) :: boolean()
  def control?(message) when is_map(message) do
    # `streaming_method?/1` is first so the extraction cost is paid only by
    # messages that are candidates for coalescing in the first place.
    not streaming_method?(message) or carries_accounting?(message)
  end

  def control?(_message), do: true

  @doc false
  @spec coalesce_interval_ms() :: pos_integer()
  def coalesce_interval_ms, do: @coalesce_interval_ms

  defp forward?(issue_id, message, now_ms) do
    cond do
      control?(message) ->
        true

      window_open?(issue_id, now_ms) ->
        false

      true ->
        Process.put(window_key(issue_id), now_ms)
        true
    end
  end

  defp window_open?(issue_id, now_ms) do
    case Process.get(window_key(issue_id)) do
      last_ms when is_integer(last_ms) -> now_ms - last_ms < @coalesce_interval_ms
      _never -> false
    end
  end

  defp window_key(issue_id), do: {__MODULE__, issue_id}

  defp carries_accounting?(message) do
    present?(message, :usage) or present?(message, "usage") or
      present?(message, :rate_limits) or present?(message, "rate_limits") or
      not is_nil(session_id(message)) or
      not empty?(Payloads.extract_token_usage(message)) or
      not empty?(Payloads.extract_rate_limits(message))
  end

  defp present?(message, key), do: not empty?(Map.get(message, key))

  # `TokenAccounting.session_id_for_update/2` reads the atom key; accept the
  # string form too rather than assume every backend normalizes it.
  defp session_id(message), do: Map.get(message, :session_id) || Map.get(message, "session_id")

  defp streaming_method?(message) do
    method(message) in @streaming_methods
  end

  # The method lives on the raw notification payload; `event` is only the coarse
  # kind (`:notification`), which is far too broad to coalesce on by itself.
  defp method(message) do
    payload = Map.get(message, :payload) || Map.get(message, "payload")

    case payload do
      %{} = payload -> Map.get(payload, "method") || Map.get(payload, :method)
      _ -> nil
    end
  end

  defp empty?(nil), do: true
  defp empty?(map) when map_size(map) == 0, do: true
  defp empty?(_), do: false
end
