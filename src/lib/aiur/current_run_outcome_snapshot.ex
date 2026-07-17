defmodule Aiur.CurrentRunOutcomeSnapshot do
  @moduledoc """
  Read API for merge outcomes associated with the current run.

  Association is deliberately conservative: the configured repository,
  canonical ticket branch locator, unique current-run membership, and
  inclusive run window must all agree. This is evidence of association, not
  proof that Aiur caused a merge. Observation provenance is returned for
  auditability but never used to qualify an outcome.

  Public states distinguish `:healthy`, `:healthy_empty`, `:partial`,
  `:stale`, and `:unavailable`. Results are deduplicated, deterministically
  ordered, and capped; invalid or truncated input is surfaced as partial
  completeness rather than silently treated as complete.
  """

  @spec version() :: pos_integer()
  def version, do: 1

  @spec project(map()) :: map()
  def project(inputs), do: Aiur.CurrentRunOutcomeSnapshot.Projection.snapshot(inputs)

  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []), do: Aiur.CurrentRunProjections.snapshot(:outcomes, opts)

  @spec health(keyword()) :: map()
  def health(opts \\ []), do: Aiur.CurrentRunProjections.health(:outcomes, opts)

  @spec freshness(keyword()) :: map()
  def freshness(opts \\ []), do: Aiur.CurrentRunProjections.freshness(:outcomes, opts)

  @spec generation(keyword()) :: non_neg_integer()
  def generation(opts \\ []), do: Aiur.CurrentRunProjections.generation(:outcomes, opts)

  @spec subscribe(keyword()) :: :ok | {:error, term()}
  def subscribe(opts \\ []) do
    Phoenix.PubSub.subscribe(Keyword.get(opts, :pubsub, Aiur.PubSub), topic())
  end

  @spec topic() :: String.t()
  def topic, do: "current-run-outcomes:changed"
end
