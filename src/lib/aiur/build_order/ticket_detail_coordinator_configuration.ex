defmodule Aiur.BuildOrder.TicketDetailCoordinator.Configuration do
  @moduledoc false

  alias Aiur.BuildOrder.TicketDetail
  alias Aiur.BuildOrder.TicketDetail.{Failure, Repository}
  alias Aiur.BuildOrder.TicketDetailCoordinator.{Policy, TaskLifecycle}

  @spec reconcile(map()) ::
          {:ok, Aiur.TrackerIdentity.repository(), map(), [Aiur.BuildOrder.TicketDetail.State.t()]}
          | {:error, Failure.t(), map(), [Aiur.BuildOrder.TicketDetail.State.t()]}
  @spec reconcile(map(), pos_integer() | nil) ::
          {:ok, Aiur.TrackerIdentity.repository(), map(), [Aiur.BuildOrder.TicketDetail.State.t()]}
          | {:error, Failure.t(), map(), [Aiur.BuildOrder.TicketDetail.State.t()]}
  def reconcile(state, notified_generation \\ nil) do
    case TicketDetail.configured_repository_snapshot(detail_opts(state, notified_generation)) do
      {:ok, repository, generation} ->
        {state, updates} = reset_if_configuration_changed(state, repository, generation)
        {state, recovery_updates} = TaskLifecycle.configuration_recovered(state)
        {:ok, repository, state, updates ++ recovery_updates}

      {:error, %Failure{} = failure} ->
        # A malformed or temporarily unreadable configuration cannot prove the
        # configured repository changed. Keep the healthy LKG until a validated
        # generation says otherwise.
        {state, updates} = TaskLifecycle.configuration_failed(state)
        {:error, failure, state, updates}
    end
  end

  defp reset_if_configuration_changed(state, repository, generation) do
    if repositories_match?(state.active_repository, repository) and
         state.active_configuration_generation == generation do
      {state, []}
    else
      state = TaskLifecycle.cancel_all(state)
      {state, updates} = Policy.evict_all(state)

      {%{state | active_repository: repository, active_configuration_generation: generation}, updates}
    end
  end

  defp repositories_match?({_, _} = left, {_, _} = right), do: Repository.same_repository?(left, right)
  defp repositories_match?(_left, _right), do: false

  defp detail_opts(state, notified_generation) do
    []
    |> maybe_put(:configured_repo, state.configured_repo)
    |> maybe_put(:configuration_snapshot, state.configuration_snapshot)
    |> maybe_put(:configuration_generation, configured_generation(state, notified_generation))
  end

  defp configured_generation(_state, generation) when is_integer(generation) and generation > 0,
    do: generation

  defp configured_generation(%{configuration_generation: generation}, _notified_generation)
       when is_function(generation, 0),
       do: generation

  defp configured_generation(%{active_configuration_generation: generation}, _notified_generation)
       when is_integer(generation) and generation > 0,
       do: generation

  defp configured_generation(state, _notified_generation), do: state.configuration_generation

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
