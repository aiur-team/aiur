defmodule Aiur.BuildOrder.TicketDetailCache.Configuration do
  @moduledoc false

  alias Aiur.BuildOrder.TicketDetail
  alias Aiur.BuildOrder.TicketDetail.{Failure, Repository}
  alias Aiur.BuildOrder.TicketDetailCache.{Policy, TaskLifecycle}

  @spec reconcile(map()) ::
          {:ok, Aiur.TrackerIdentity.repository(), map(), [Aiur.BuildOrder.TicketDetail.State.t()]}
          | {:error, Failure.t(), map(), [Aiur.BuildOrder.TicketDetail.State.t()]}
  def reconcile(state) do
    case TicketDetail.configured_repository(detail_opts(state)) do
      {:ok, repository} ->
        {state, updates} = reset_if_repository_changed(state, repository)
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

  defp reset_if_repository_changed(%{active_repository: active_repository} = state, repository) do
    if active_repository == repository or repositories_match?(active_repository, repository) do
      {state, []}
    else
      state = TaskLifecycle.cancel_all(state)
      {state, updates} = Policy.evict_all(state)
      {%{state | active_repository: repository}, updates}
    end
  end

  defp repositories_match?({_, _} = left, {_, _} = right), do: Repository.same_repository?(left, right)
  defp repositories_match?(_left, _right), do: false

  defp detail_opts(%{configured_repo: nil}), do: []
  defp detail_opts(%{configured_repo: configured_repo}), do: [configured_repo: configured_repo]
end
