defmodule Aiur.BuildOrder.Index.Sources do
  @moduledoc false
  alias Aiur.BuildOrder.{ProviderHealth, SourceFreshness}

  alias Aiur.BuildOrder.Index.Estimates

  @spec build(map(), integer()) :: map()
  def build(parts, now) do
    sources = %{
      history: history(parts),
      packs: pack_source(parts[:packs], now),
      estimates: Estimates.source(parts[:estimates]),
      features: SourceFreshness.source(health(parts[:features])),
      queue: producer(parts[:planned]),
      agents: producer(parts[:now]),
      open_tickets: open_tickets(parts[:not_queued]),
      index: %{state: "ok", observed_at: now, reason: nil}
    }

    apply_read_staleness(sources, parts[:read_stale] || %{})
  end

  @spec health(term()) :: term()
  def health({:ok, %{health: health}}), do: health
  def health({:error, %ProviderHealth{} = health}), do: health
  def health({:error, reason}) when is_atom(reason), do: %ProviderHealth{failure: reason}
  def health(_), do: %ProviderHealth{failure: :unknown}

  defp pack_source(%{source: source}, _now), do: source
  defp pack_source(_, now), do: %{state: "unavailable", observed_at: now, reason: "planning packs could not be read"}

  defp history(parts) do
    health = parts[:health]

    source =
      case health do
        %ProviderHealth{state: state} when state in [:unavailable, :structurally_invalid] -> SourceFreshness.source(health)
        {:error, _} = failure -> SourceFreshness.source(health(failure))
        _ -> SourceFreshness.source(health(parts[:history]))
      end

    cond do
      source.state == "unavailable" -> source
      match?(%ProviderHealth{complete?: false}, health) -> %{source | state: "incomplete", reason: to_string(health.failure || :incomplete)}
      true -> catch_up(source, parts[:catch_up])
    end
  end

  defp catch_up(source, %{status: status, at: at}) when status in [:held, :failed],
    do: %{source | state: "stale", reason: "catch_up_#{status}", observed_at: older(source.observed_at, SourceFreshness.ms(at))}

  defp catch_up(source, {:error, reason}), do: %{source | state: "stale", reason: "catch_up_#{reason}"}
  defp catch_up(source, _), do: source
  defp older(nil, _), do: nil
  defp older(_, nil), do: nil
  defp older(a, b), do: min(a, b)
  defp producer(%{source: source}), do: source
  defp producer(_), do: %{state: "unavailable", observed_at: nil, reason: "read_failed"}

  defp open_tickets(%{state: state, reasons: reasons, observed_at: at, truncated?: truncated}) do
    %{state: to_string(state), observed_at: SourceFreshness.ms(at), reason: if(reasons == [], do: nil, else: Enum.join(reasons, ",")), truncated: truncated}
  end

  defp open_tickets(_), do: %{state: "unavailable", observed_at: nil, reason: "read_failed", truncated: false}

  defp apply_read_staleness(sources, stale_parts) do
    Enum.reduce(stale_parts, sources, fn {part, reason}, acc ->
      case source_key(part) do
        nil -> acc
        key -> Map.update!(acc, key, &stale_source(&1, reason))
      end
    end)
  end

  defp stale_source(source, reason) do
    state = if source.state in ["ok", "stale"], do: "stale", else: source.state
    preserve_reason? = source.state == "unavailable" and source.reason not in [nil, "read_failed", "unknown"]
    %{source | state: state, reason: if(preserve_reason?, do: source.reason, else: reason_name(reason))}
  end

  defp source_key(part) when part in [:history, :health, :catch_up], do: :history
  defp source_key(:estimates), do: :estimates
  defp source_key(:features), do: :features
  defp source_key(part) when part in [:queue, :planned], do: :queue
  defp source_key(:now), do: :agents
  defp source_key(part) when part in [:open, :not_queued], do: :open_tickets
  defp source_key(part) when part in [:overrides, :settings, :repository], do: :index
  defp source_key(_part), do: nil

  defp reason_name(:timeout), do: "timeout"
  defp reason_name(:read_failed), do: "read_failed"
  defp reason_name(:unknown), do: "unknown"
  defp reason_name(_reason), do: "unknown"
end
