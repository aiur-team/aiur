defmodule Aiur.CurrentRunSummary do
  @moduledoc """
  Read API for the versioned current-run summary projection.

  Progress values are exact integer fractions, never rounded display values.
  `progress.exact` is present only when the run window, membership
  reconciliation, source health, and every eligible member's weight and
  progress are known. Otherwise `lower_bound` and `coverage` preserve the
  known portion without inventing certainty.

  ETA uses completed eligible weight over Boot's elapsed wall time. It is
  available only after two successful completions, ten elapsed minutes, and
  healthy, fresh membership and weight facts. Public health states are
  `:healthy`, `:partial`, and `:unavailable`; freshness additionally reports
  `:fresh`, `:partial`, `:stale`, `:unknown`, or `:unavailable`.
  """

  @spec version() :: pos_integer()
  def version, do: 1

  @spec project(map()) :: map()
  def project(inputs), do: Aiur.CurrentRunSummary.Projection.snapshot(inputs)

  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []), do: Aiur.CurrentRunProjections.snapshot(:summary, opts)

  @spec health(keyword()) :: map()
  def health(opts \\ []), do: Aiur.CurrentRunProjections.health(:summary, opts)

  @spec freshness(keyword()) :: map()
  def freshness(opts \\ []), do: Aiur.CurrentRunProjections.freshness(:summary, opts)

  @spec generation(keyword()) :: non_neg_integer()
  def generation(opts \\ []), do: Aiur.CurrentRunProjections.generation(:summary, opts)

  @spec subscribe(keyword()) :: :ok | {:error, term()}
  def subscribe(opts \\ []) do
    Phoenix.PubSub.subscribe(Keyword.get(opts, :pubsub, Aiur.PubSub), topic())
  end

  @spec topic() :: String.t()
  def topic, do: "current-run-summary:changed"
end
