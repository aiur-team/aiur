defmodule AgentConversation.Labels do
  @moduledoc """
  Reader-facing text for conversation states and observation ages.

  Hosts may override any label in their own copy; these exist so an embed that
  supplies nothing still reads sensibly. Freshness turns `:stale` after ten
  minutes without an observation, which is the threshold the dashboard uses.
  """

  @fresh_window_ms 600_000

  @doc "The default label for a transcript state."
  @spec state(atom()) :: String.t()
  def state(:loading), do: "Loading conversation…"
  def state(:ready), do: "Live"
  def state(:live), do: "Live"
  def state(:idle), do: "Idle"
  def state(:empty), do: "No messages yet"
  def state(:known_empty), do: "No messages yet"
  def state(:not_found), do: "Conversation not found"
  def state(:unavailable), do: "Conversation unavailable"
  def state(:denied), do: "This conversation is outside your scope"
  def state(:degraded), do: "Stale — the journal is unavailable"
  def state(:ended), do: "Ended"
  def state(:restart_unknown), do: "Continuity unknown"
  def state(:unknown), do: "Conversation state unknown"
  def state(other), do: to_string(other)

  @doc """
  The observation age of a transcript.

  Returns `%{observed_at: DateTime.t() | nil, age_ms: integer | nil, freshness:
  :fresh | :stale | :unknown, text: String.t()}`. The text is the only part most
  hosts show.
  """
  @spec age(DateTime.t() | String.t() | nil, DateTime.t()) :: map()
  def age(observed_at, now \\ DateTime.utc_now()) do
    case timestamp(observed_at) do
      nil -> %{observed_at: nil, age_ms: nil, freshness: :unknown, text: "age unknown"}
      at -> fields(at, max(0, DateTime.diff(now, at, :millisecond)))
    end
  end

  defp fields(at, ms) do
    %{
      observed_at: at,
      age_ms: ms,
      freshness: if(ms <= @fresh_window_ms, do: :fresh, else: :stale),
      text: "#{div(ms, 1000)} seconds ago"
    }
  end

  defp timestamp(%DateTime{} = at), do: at

  defp timestamp(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, time, _offset} -> time
      _error -> nil
    end
  end

  defp timestamp(_at), do: nil
end
