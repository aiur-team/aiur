defmodule Aiur.Usage.Headless.Compatibility do
  @moduledoc """
  Thin compatibility projection for existing transient token consumers.

  DASH-029 keeps the legacy running-row consumers working without teaching them
  the full envelope. This projection reuses the DASH-008 reconciliation and the
  legacy `Aiur.TokenUsage.canonicalize/1` contract; it derives no cross-message
  delta and never zero-fills an unknown dimension into a canonical total.
  """

  alias Aiur.{TokenUsage, UsageEnvelope}
  alias Aiur.Usage.Headless.Catalog

  @spec project(UsageEnvelope.t()) :: {:ok, map()} | {:error, atom()}
  def project(%UsageEnvelope{} = envelope) do
    UsageEnvelope.compatibility_projection(envelope, Catalog.relationship_catalog())
  end

  @doc "Preserves the legacy canonical usage contract for consumers not yet migrated."
  @spec canonical(term()) :: TokenUsage.canonical_usage() | nil
  def canonical(raw_usage), do: TokenUsage.canonicalize(raw_usage)
end
