defmodule Aiur.BuildOrder.Index.Sources do
  @moduledoc false
  alias Aiur.BuildOrder.{ProviderHealth, SourceFreshness}

  @spec build(map(), integer()) :: map()
  def build(parts, now) do
    %{
      history: history(parts),
      features: SourceFreshness.source(health(parts[:features])),
      queue: producer(parts[:planned]),
      agents: producer(parts[:now]),
      open_tickets: open_tickets(parts[:not_queued]),
      index: %{state: "ok", observed_at: now, reason: nil}
    }
  end

  @spec health(term()) :: term()
  def health({:ok, %{health: health}}), do: health
  def health({:error, %ProviderHealth{} = health}), do: health
  def health({:error, reason}) when is_atom(reason), do: %ProviderHealth{failure: reason}
  def health(_), do: %ProviderHealth{failure: :unknown}

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
end
