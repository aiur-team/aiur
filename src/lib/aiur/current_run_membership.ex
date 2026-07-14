defmodule Aiur.CurrentRunMembership do
  @moduledoc """
  Headless-safe, current-run membership projection.

  The projection stores only typed ticket identity and lifecycle facts. It is
  not a lifecycle authority: callers must obtain their observations from the
  tracker or `Aiur.Orchestrator.StatusReport`.
  """

  alias Aiur.CurrentRunMembership.{Event, Store}
  alias Aiur.TrackerIdentity

  @pubsub Aiur.PubSub
  @topic "current-run-membership:changed"

  @spec start_link(keyword()) :: GenServer.on_start()
  defdelegate start_link(opts \\ []), to: Store

  @spec observe(TrackerIdentity.t(), Event.lifecycle(), keyword()) :: {:ok, map()} | {:error, term()}
  def observe(identity, lifecycle, opts \\ []), do: Store.observe(identity, lifecycle, opts)

  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []), do: Store.snapshot(opts)

  @spec lookup(TrackerIdentity.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup(identity), do: Store.lookup(identity)

  @spec generation() :: non_neg_integer()
  def generation, do: Store.generation()

  @spec health() :: term()
  def health, do: Store.health()

  @spec freshness() :: map()
  def freshness, do: Store.freshness()

  @spec mark_reconciled(:fresh | :unavailable) :: :ok
  def mark_reconciled(status), do: Store.mark_reconciled(status)

  @doc false
  @spec set_terminal_verification_pending(TrackerIdentity.t(), boolean()) :: :ok | {:error, :terminal_verification_marker_failed}
  def set_terminal_verification_pending(identity, pending?), do: Store.set_terminal_verification_pending(identity, pending?)

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @doc false
  @spec broadcast_changed(String.t(), non_neg_integer(), Event.t() | nil, term(), map()) :: :ok
  def broadcast_changed(run_id, generation, event, health, freshness) do
    if is_pid(Process.whereis(@pubsub)) do
      message =
        case event do
          %Event{} ->
            {:current_run_membership_changed, changed_payload(run_id, generation, event, health, freshness)}

          nil ->
            {:current_run_membership_health_changed, changed_payload(run_id, generation, nil, health, freshness)}
        end

      Phoenix.PubSub.broadcast(@pubsub, @topic, message)
    end

    :ok
  end

  defp changed_payload(run_id, generation, event, health, freshness) do
    %{run_id: run_id, generation: generation, event: event, health: health, freshness: freshness}
  end
end
