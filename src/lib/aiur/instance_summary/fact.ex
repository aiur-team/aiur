defmodule Aiur.InstanceSummary.Fact do
  @moduledoc "Value-free degraded facts for the instance summary wire contract."

  @type status :: :available | :unavailable | :disabled | :unknown
  @type t :: %{
          optional(:value) => term(),
          status: status(),
          observed_at: String.t(),
          age_ms: non_neg_integer(),
          reason: String.t() | nil,
          freshness: :current | :stale | nil
        }

  @spec available(term(), String.t(), keyword()) :: t()
  def available(value, observed_at, opts \\ []) do
    %{status: :available, value: value, observed_at: observed_at, age_ms: Keyword.get(opts, :age_ms, 0), reason: nil, freshness: Keyword.get(opts, :freshness, :current)}
  end

  @spec unavailable(String.t()) :: t()
  def unavailable(reason), do: degraded(:unavailable, reason)

  @spec disabled(String.t()) :: t()
  def disabled(reason), do: degraded(:disabled, reason)

  @spec unknown(String.t()) :: t()
  def unknown(reason), do: degraded(:unknown, reason)

  defp degraded(status, reason) do
    %{status: status, observed_at: DateTime.to_iso8601(DateTime.utc_now()), age_ms: 0, reason: reason, freshness: nil}
  end
end
