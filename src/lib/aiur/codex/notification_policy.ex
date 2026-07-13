defmodule Aiur.Codex.NotificationPolicy do
  @moduledoc """
  Pure predicates for classifying Codex notifications, errors, and quota events.
  """

  # Identify error-class notifications that should be surfaced at info
  # level with their payload, not buried at debug. Codex sends "error"
  # as a top-level method when the API itself fails (rate limit, auth,
  # transport timeout). It also sends `*/error`-suffixed methods for
  # subsystem failures. Without these surfacing rules an Executor
  # debugging a stuck agent has to enable debug logging globally and
  # then grep through 1000s of lines of routine MCP notifications.
  @spec codex_error_method?(String.t()) :: boolean()
  def codex_error_method?(method) when is_binary(method) do
    method == "error" or String.ends_with?(method, "/error")
  end

  @spec needs_input?(String.t(), map()) :: boolean()
  def needs_input?(method, payload)
      when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  def needs_input?(_method, _payload), do: false

  @spec turn_started_method?(String.t()) :: boolean()
  def turn_started_method?("turn/started"), do: true
  def turn_started_method?(_method), do: false

  @spec thread_idle_status?(String.t(), map()) :: boolean()
  def thread_idle_status?("thread/status/changed", %{"params" => %{"status" => %{"type" => "idle"}}}), do: true
  def thread_idle_status?("thread/status/changed", %{"status" => %{"type" => "idle"}}), do: true
  def thread_idle_status?(_method, _payload), do: false

  @spec checkpoint_for_method(String.t()) :: map()
  def checkpoint_for_method("item/tool/call"), do: %{kind: :tool_result, method: "item/tool/call"}
  def checkpoint_for_method(method), do: %{kind: :notification, method: method}

  @spec protocol_message_candidate?(String.t() | term()) :: boolean()
  def protocol_message_candidate?(payload_string) do
    payload_string
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?(["{", "["])
  end

  # Codex says "no active turn to interrupt" (-32600). The turn ended on its
  # own between us deciding to interrupt and codex processing the request.
  # The -32600 / "no active turn" tolerance keeps the interrupt path from
  # crashing the agent when a fresh task receives an Executor-queue update
  # before its first codex turn has spawned (FI-CDX-035).
  @spec no_active_turn_error?(term()) :: boolean()
  def no_active_turn_error?(%{"code" => -32_600}), do: true

  def no_active_turn_error?(%{"message" => message}) when is_binary(message) do
    String.contains?(message, "no active turn")
  end

  def no_active_turn_error?(_), do: false

  # The flag can ride on the notification root or inside `params`, and
  # codex has used both camelCase and snake_case across versions, so
  # check all four positions (mirrors `request_payload_requires_input?`).
  @spec unretryable_codex_error?(map()) :: boolean()
  def unretryable_codex_error?(payload) do
    will_retry_false?(payload) || will_retry_false?(Map.get(payload, "params"))
  end

  # Quota exhaustion is the subset of *unretryable* error-method turn failures
  # (codex sets willRetry:false when the account quota is gone) whose detail
  # names a usage limit. Gating on `unretryable_codex_error?` as well keeps a
  # merely transient error that happens to mention "usage limit" from stranding
  # the agent in a pause — a pause has no auto-resume timer, so such errors must
  # fall through to the normal retry path instead.
  @spec codex_quota_exhausted?(String.t(), map()) :: boolean()
  def codex_quota_exhausted?(method, payload) do
    codex_error_method?(method) and unretryable_codex_error?(payload) and
      usage_limit_exceeded?(payload)
  end

  # Pause payload for a quota-exhaustion turn error. `kind` lets the agent
  # runner emit the Executor alert; `reset_hint` carries the human-readable
  # "try again at …" time when codex provides one.
  @spec usage_limit_pause(map(), String.t()) :: map()
  def usage_limit_pause(payload, method) do
    %{
      kind: :usage_limit_exhausted,
      reason: codex_error_reason(payload, method),
      reset_hint: usage_limit_reset_hint(payload)
    }
  end

  # Best-effort human-readable reason for the failure tuple/log/alert. Control
  # flow keys only on `willRetry`; the detail field name varies across codex
  # versions, so check the known positions (root + params + nested error) and
  # fall back to the method when no recognizable detail is present — never the
  # bare opaque `"error"` when a detail is actually available.
  @spec codex_error_reason(map(), String.t()) :: String.t()
  def codex_error_reason(payload, method) do
    case codex_error_detail(payload) do
      detail when is_binary(detail) and detail != "" -> "#{method}: #{detail}"
      _ -> method
    end
  end

  # A `usageLimitExceeded` turn error means the codex/ChatGPT account quota is
  # exhausted (it resets at a stated time) — NOT a transient rate limit, so
  # immediate retries cannot help and only burn the agent's retry budget into
  # `agent:error`. Detect it robustly (codex stashes the marker under different
  # keys across versions) and route the turn to a pause + Executor alert. The
  # inspected-payload scan mirrors the agent runner's `more_tokens_reason?` and
  # survives field-name drift. Kept total (no `is_map` guard) so a malformed
  # non-map payload degrades to `false` rather than crashing the receive loop.
  @spec usage_limit_exceeded?(map()) :: boolean()
  def usage_limit_exceeded?(payload) do
    payload
    |> inspect()
    |> String.downcase()
    |> String.contains?(["usagelimitexceeded", "usage limit"])
  end

  # Best-effort: pull the "try again at 11:43 PM" reset time out of whatever
  # human message codex attached. Returns nil when no such phrase is present.
  # Kept total (no `is_map` guard) to match `usage_limit_exceeded?/1`.
  @spec usage_limit_reset_hint(map()) :: String.t() | nil
  def usage_limit_reset_hint(payload) do
    case Regex.run(~r/try again at ([^."\n]+)/i, inspect(payload)) do
      [_, when_str] -> String.trim(when_str)
      _ -> nil
    end
  end

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false

  defp will_retry_false?(payload) when is_map(payload) do
    Map.get(payload, "willRetry") == false or Map.get(payload, "will_retry") == false
  end

  defp will_retry_false?(_payload), do: false

  defp codex_error_detail(payload) do
    params = Map.get(payload, "params") || %{}
    params_error = ensure_map(Map.get(params, "error"))
    root_error = ensure_map(Map.get(payload, "error"))
    nested = Map.merge(params_error, root_error)

    [
      Map.get(params, "message"),
      Map.get(params, "codexErrorInfo"),
      Map.get(nested, "message"),
      Map.get(params, "type"),
      Map.get(params, "code"),
      Map.get(nested, "type"),
      Map.get(nested, "code"),
      Map.get(payload, "message")
    ]
    |> Enum.find(fn value -> is_binary(value) and value != "" end)
  end

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_value), do: %{}
end
