defmodule Aiur.Claude.NotificationPolicy do
  @moduledoc false

  @limit_markers [
    "rate limit",
    "rate_limit",
    "ratelimit",
    "usage limit",
    "usage_limit",
    # The account-wide refusal reads "You've hit your session limit · resets
    # 11:40pm" and never says "rate limit" (#2607).
    "session limit",
    "session_limit",
    "quota",
    "too many requests",
    "credit balance",
    "insufficient credits"
  ]
  @limit_statuses [429, "429"]
  @limit_types ["rate_limit_error", "rate_limit"]

  # Free-text 429s, anchored so an unrelated "429" (a line number, a token
  # count) in provider stream output is not read as an exhaustion signal.
  @limit_text_patterns [
    ~r{\bhttp[\s/]*[\d.]*\s*429\b}i,
    ~r/\b(?:status|status_code|statuscode|code|error)\b[^\n]{0,24}\b429\b/i,
    ~r/\b429\b[^\n]{0,24}\btoo many requests\b/i
  ]

  # "· resets 11:40pm (America/Los_Angeles)" / "resets at 6:40am".
  @reset_hint_pattern ~r/\bresets?\s+(?:at\s+)?(?<hint>[^\n·|]{1,60})/i

  @spec usage_limit_exhausted?(term()) :: boolean()
  def usage_limit_exhausted?(payload) when is_map(payload) do
    Enum.any?(
      find_values(payload, [
        "status",
        :status,
        "status_code",
        :status_code,
        "api_error_status",
        :api_error_status
      ]),
      &(&1 in @limit_statuses)
    ) or
      Enum.any?(
        find_values(payload, ["type", :type, "code", :code, "error", :error]),
        &(&1 in @limit_types)
      ) or
      payload_text(payload) |> String.downcase() |> String.contains?(@limit_markers)
  end

  def usage_limit_exhausted?(text) when is_binary(text), do: limit_text?(text)

  def usage_limit_exhausted?(_payload), do: false

  @doc """
  Classifies free-text provider output — the non-JSON lines a refusing `claude`
  prints before exiting — as a usage-limit pause or nothing at all.

  This is the stream-side twin of the in-stream `rate_limit/update`
  notification: an account-level refusal at turn start never arrives as a
  structured event, so without it the exit settles as a generic turn failure
  and the rate-limit fallback never runs (#2607).
  """
  @spec classify_stream_failure(String.t()) :: {:paused, map()} | :unclassified
  def classify_stream_failure(text) when is_binary(text) do
    if limit_text?(text), do: {:paused, usage_limit_pause_from_text(text)}, else: :unclassified
  end

  def classify_stream_failure(_text), do: :unclassified

  @doc """
  Pause payload for a limit signature recognised in free-text provider output.
  The reason keeps the matching line so the Executor sees the provider's own
  wording, and the reset hint is lifted from a "resets <time>" phrase.
  """
  @spec usage_limit_pause_from_text(String.t()) :: map()
  def usage_limit_pause_from_text(text) when is_binary(text), do: text |> matching_line() |> usage_limit_pause()

  @doc """
  The "resets <time>" hint carried by free text, or nil when it has none.
  """
  @spec reset_hint(String.t()) :: String.t() | nil
  def reset_hint(text) when is_binary(text) do
    case Regex.named_captures(@reset_hint_pattern, text) do
      %{"hint" => hint} ->
        case String.trim(hint) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  def reset_hint(_text), do: nil

  defp limit_text?(text) do
    downcased = String.downcase(text)

    String.contains?(downcased, @limit_markers) or
      Enum.any?(@limit_text_patterns, &Regex.match?(&1, text))
  end

  # Retained output is several lines of provider noise; report the one that
  # actually matched rather than the whole buffer.
  defp matching_line(text) do
    text
    |> String.split("\n")
    |> Enum.find(&limit_text?/1)
    |> case do
      nil -> String.trim(text)
      line -> String.trim(line)
    end
  end

  @spec usage_limit_pause(term()) :: map()
  def usage_limit_pause(payload) do
    reason = error_reason(payload)

    %{
      kind: :usage_limit_exhausted,
      reason: reason,
      # A structured reset field when the provider sent one; otherwise the
      # "resets <time>" the refusal states in prose, which is the only form the
      # session-limit banner carries.
      reset_hint: find_value(payload, ["reset_at", :reset_at, "resetAt", :resetAt]) || reset_hint(reason)
    }
  end

  @spec error_reason(term()) :: String.t()
  def error_reason(payload) do
    case payload_text(payload) do
      "" -> "Claude usage limit exhausted"
      text -> text
    end
  end

  defp payload_text(payload) do
    payload
    |> flatten_values()
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  defp flatten_values(value) when is_map(value),
    do: Enum.flat_map(value, fn {key, item} -> [key | flatten_values(item)] end)

  defp flatten_values(value) when is_list(value), do: Enum.flat_map(value, &flatten_values/1)
  defp flatten_values(value), do: [value]

  defp find_value(payload, keys), do: payload |> find_values(keys) |> List.first()

  defp find_values(payload, keys) when is_map(payload) do
    values = Enum.flat_map(keys, &(Map.get(payload, &1) |> List.wrap()))
    nested = payload |> Map.values() |> Enum.flat_map(&find_values(&1, keys))
    values ++ nested
  end

  defp find_values(payload, keys) when is_list(payload),
    do: Enum.flat_map(payload, &find_values(&1, keys))

  defp find_values(_payload, _keys), do: []
end
