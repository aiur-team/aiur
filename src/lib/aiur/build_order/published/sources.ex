defmodule Aiur.BuildOrder.Published.Sources do
  @moduledoc """
  Per-source availability records for `build-order.v1`.

  A source is `known` only when its read completed, `stale` when the projection
  holds a last-known or partial generation, and `unknown` when nothing usable
  was read. An unknown source always carries a reason, so a reader never renders
  an unavailable reading as an empty one.
  """

  alias Aiur.BuildOrder.ProviderHealth

  @type record :: %{optional(String.t()) => String.t() | nil}

  @spec pack(map(), String.t()) :: record()
  def pack(metadata, fallback_reason) do
    if is_map(metadata) and map_size(metadata) > 0 do
      %{"status" => "known", "observed_at" => nil, "reason" => nil}
    else
      %{"status" => "unknown", "observed_at" => nil, "reason" => fallback_reason}
    end
  end

  @doc "A catalog document is not derived from one planning pack."
  @spec catalog_pack() :: record()
  def catalog_pack,
    do: %{"status" => "unknown", "observed_at" => nil, "reason" => "catalog_scope"}

  @spec tracker(term()) :: record()
  def tracker(%ProviderHealth{} = health) do
    %{
      "status" => word(health),
      "observed_at" => iso8601(health.observed_at || health.last_success_at),
      "reason" => reason(health)
    }
  end

  def tracker(_health),
    do: %{"status" => "unknown", "observed_at" => nil, "reason" => "provider_unavailable"}

  @spec available?(term()) :: boolean()
  def available?(%ProviderHealth{} = health), do: ProviderHealth.usable?(health)
  def available?(_health), do: false

  @doc """
  The progress source repeats the tracker verdict and adds a failed count read
  as stale evidence. A zero is never published in place of an unknown count.
  """
  @spec progress(record(), String.t() | nil) :: record()
  def progress(%{"status" => "unknown"} = tracker, _counts_reason), do: tracker
  def progress(%{"status" => "stale"} = tracker, _counts_reason), do: tracker

  def progress(%{"observed_at" => observed_at}, nil),
    do: %{"status" => "known", "observed_at" => observed_at, "reason" => nil}

  def progress(%{"observed_at" => observed_at}, counts_reason),
    do: %{"status" => "stale", "observed_at" => observed_at, "reason" => counts_reason}

  @spec reason(term()) :: String.t() | nil
  def reason(%ProviderHealth{state: :healthy, complete?: true}), do: nil
  def reason(%ProviderHealth{state: :healthy, failure: failure}), do: word_or(failure, "incomplete_read")
  def reason(%ProviderHealth{state: :stale, failure: failure}), do: word_or(failure, "stale_generation")
  def reason(%ProviderHealth{state: :structurally_invalid}), do: "structurally_invalid"
  def reason(%ProviderHealth{failure: failure}), do: word_or(failure, "provider_unavailable")
  def reason(_health), do: "provider_unavailable"

  @spec iso8601(term()) :: String.t() | nil
  def iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def iso8601(_value), do: nil

  defp word(%ProviderHealth{state: :healthy, complete?: true}), do: "known"
  defp word(%ProviderHealth{state: :healthy}), do: "stale"
  defp word(%ProviderHealth{state: :stale}), do: "stale"
  defp word(_health), do: "unknown"

  defp word_or(value, _fallback) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp word_or(_value, fallback), do: fallback
end
