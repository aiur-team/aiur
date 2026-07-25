defmodule Aiur.Usage.Headless.Normalizer do
  @moduledoc """
  Dispatches one raw headless payload to the pinned adapters for its provider.

  The normalizer selects only adapters whose provider matches the trusted
  context and whose pinned source revision matches the installed one. A source
  whose observed revision has drifted forward is never mapped with current
  semantics; it yields bounded `unsupported_source_revision` coverage. Each
  accepted adapter produces at most one raw envelope identity, so overlapping
  absolute and delta streams remain distinct for the DASH-009 single writer.
  """

  alias Aiur.Usage.Headless.{Adapter, Catalog, Context}
  alias Aiur.UsageEnvelope

  @type outcome :: %{envelopes: [UsageEnvelope.t()], coverages: [Adapter.coverage()]}

  @spec normalize(map(), String.t() | nil, Context.t(), DateTime.t()) :: outcome()
  def normalize(payload, raw, %Context{} = context, %DateTime{} = ingested_at) when is_map(payload) do
    context.agent_family
    |> Catalog.adapters_for()
    |> Enum.flat_map(&run_adapter(&1, payload, raw, context, ingested_at))
    |> split()
  end

  def normalize(_payload, _raw, _context, _ingested_at), do: %{envelopes: [], coverages: []}

  defp run_adapter(adapter, payload, raw, context, ingested_at) do
    if drifted?(adapter, context) do
      [{:coverage, Adapter.coverage(adapter, :unsupported_source_revision, :source_version)}]
    else
      adapter.extract(payload, raw, context, ingested_at)
    end
  end

  # A characterized-at-pickup source version pins the mapping. When the running
  # protocol reports a different revision, refuse to fall forward.
  defp drifted?(adapter, %Context{observed_source_version: observed}) do
    is_binary(observed) and observed != adapter.source_version()
  end

  defp split(results) do
    Enum.reduce(results, %{envelopes: [], coverages: []}, fn
      {:ok, envelope}, acc -> %{acc | envelopes: [envelope | acc.envelopes]}
      {:coverage, coverage}, acc -> %{acc | coverages: [coverage | acc.coverages]}
    end)
    |> then(fn acc -> %{envelopes: Enum.reverse(acc.envelopes), coverages: Enum.reverse(acc.coverages)} end)
  end
end
