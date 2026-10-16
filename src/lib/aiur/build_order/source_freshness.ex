defmodule Aiur.BuildOrder.SourceFreshness do
  @moduledoc "Store source freshness shared by build projections and socket presenters."
  alias Aiur.BuildOrder.ProviderHealth

  @spec source(term()) :: map()
  def source(%ProviderHealth{state: :healthy} = health) do
    if ProviderHealth.usable?(health),
      do: entry("ok", health.observed_at, nil),
      else: entry("incomplete", health.observed_at, :incomplete)
  end

  def source(%ProviderHealth{state: :stale} = health), do: entry("stale", health.observed_at, health.failure)

  def source(%ProviderHealth{state: state} = health) when state in [:unavailable, :structurally_invalid],
    do: entry("unavailable", health.observed_at, health.failure || state)

  def source({:current, _, md}) when is_map(md), do: entry("ok", Map.get(md, :observed_at), nil)
  def source({:stale, _, md}) when is_map(md), do: entry("stale", Map.get(md, :observed_at), Map.get(md, :reason))
  def source(reason) when reason in [:snapshot_unpublished, :orchestrator_unavailable], do: entry("unavailable", nil, reason)
  def source({:disabled, reason}), do: entry("disabled", nil, reason)
  def source(_), do: entry("unavailable", nil, :unknown)

  @spec ms(term()) :: integer() | nil
  def ms(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
  def ms(at) when is_integer(at), do: at

  def ms(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, time, _} -> ms(time)
      _ -> nil
    end
  end

  def ms(_), do: nil
  defp entry(state, time, reason), do: %{state: state, observed_at: ms(time), reason: if(is_nil(reason), do: nil, else: to_string(reason))}
end
