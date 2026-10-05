defmodule Aiur.AllowedContributors.RateLimit do
  @moduledoc """
  Per-author rolling-window cap on accepted allowed-contributor wakes.

  A compromised allowed account must not be able to bury the Executor: past
  the cap, surplus issues are dropped (and audited as `rate_limited`), not
  queued. Pure: the caller owns the state map and the clock.
  """

  @type t :: %{optional(pos_integer()) => [integer()]}

  @doc "Admits one event for `author_id` at `now_ms`, or reports the cap is reached."
  @spec admit(t(), pos_integer(), integer(), pos_integer(), pos_integer()) :: {:ok, t()} | {:limited, t()}
  def admit(state, author_id, now_ms, limit, window_ms) do
    recent = state |> Map.get(author_id, []) |> Enum.filter(&(now_ms - &1 < window_ms))
    state = prune(state, now_ms, window_ms)

    if length(recent) >= limit,
      do: {:limited, Map.put(state, author_id, recent)},
      else: {:ok, Map.put(state, author_id, [now_ms | recent])}
  end

  @doc """
  Returns the slot `admit/5` just granted `author_id` (its newest stamp), for a
  wake that was admitted but never delivered: a deferred retry must not spend
  the author's budget, or the retries alone would rate-limit the issue away.
  """
  @spec refund(t(), pos_integer()) :: t()
  def refund(state, author_id) do
    case Map.get(state, author_id) do
      [_newest] -> Map.delete(state, author_id)
      [_newest | older] -> Map.put(state, author_id, older)
      _none -> state
    end
  end

  defp prune(state, now_ms, window_ms) do
    state
    |> Enum.map(fn {author, stamps} -> {author, Enum.filter(stamps, &(now_ms - &1 < window_ms))} end)
    |> Enum.reject(fn {_author, stamps} -> stamps == [] end)
    |> Map.new()
  end
end
