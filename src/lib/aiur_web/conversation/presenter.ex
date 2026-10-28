defmodule AiurWeb.Conversation.Presenter do
  @moduledoc "Pure conversation state and freshness presentation."

  @spec state(term(), keyword()) :: atom()
  def state(result, opts \\ [])
  def state(:loading, _opts), do: :loading
  def state({:error, :not_found}, _opts), do: :not_found
  def state({:error, _}, _opts), do: :unavailable
  def state({:ok, page}, opts), do: state(page, opts)

  def state(page, opts) do
    cond do
      opts[:degraded] -> :degraded
      page.head_pos == 0 -> :known_empty
      true -> session_state(List.last(opts[:sessions] || page.sessions), page, opts)
    end
  end

  defp session_state(nil, _page, _opts), do: :unknown
  defp session_state(%{end_reason: "daemon_restart_unknown"}, _page, _opts), do: :restart_unknown
  defp session_state(%{end_reason: reason}, _page, _opts) when reason in ["stopped", "turn_limit", "superseded", "completed"], do: :ended

  defp session_state(%{end_reason: nil, ended_at: nil}, page, opts) do
    entry = opts[:last_entry] || List.last(page.entries)
    age = age(entry && entry.observed_at, opts[:now] || DateTime.utc_now())
    if age.age_ms != nil and age.age_ms <= 600_000, do: :live, else: :idle
  end

  defp session_state(_session, _page, _opts), do: :unknown

  @spec age(DateTime.t() | String.t() | nil, DateTime.t()) :: map()
  def age(observed_at, now) do
    case timestamp(observed_at) do
      nil -> %{observed_at: nil, age_ms: nil, freshness: :unknown, text: "age unknown"}
      at -> age_fields(at, max(0, DateTime.diff(now, at, :millisecond)))
    end
  end

  defp age_fields(at, ms) do
    %{observed_at: at, age_ms: ms, freshness: if(ms <= 600_000, do: :fresh, else: :stale), text: "#{div(ms, 1000)} seconds ago"}
  end

  defp timestamp(%DateTime{} = at), do: at

  defp timestamp(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, time, _} -> time
      _ -> nil
    end
  end

  defp timestamp(_), do: nil

  @spec label(atom()) :: String.t()
  def label(:loading), do: "Loading conversation…"
  def label(:not_found), do: "Conversation not found"
  def label(:unavailable), do: "Conversation unavailable"
  def label(:known_empty), do: "No messages yet"
  def label(:live), do: "Live"
  def label(:idle), do: "Idle"
  def label(:ended), do: "Ended"
  def label(:restart_unknown), do: "Continuity unknown"
  def label(:degraded), do: "Stale — journal unavailable"
  def label(:unknown), do: "Conversation state unknown"
end
