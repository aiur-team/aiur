defmodule Aiur.Orchestrator.OptimisticDispatch do
  @moduledoc "Binds native blocker events and attaches evaluated start heads before dispatch."

  require Logger

  alias Aiur.Events.BranchRefStore
  alias Aiur.{Issue, OptimisticStart}
  alias Aiur.Orchestrator.{AutoSubscriptions, DispatchPolicy}

  @spec prepare(Issue.t(), [map()], keyword()) :: {:ok, Issue.t()} | {:error, atom()}
  def prepare(%Issue{} = issue, optimistic_blockers, opts) do
    subscriber = Keyword.get(opts, :blocker_subscriber, &AutoSubscriptions.subscribe_for_declared_blocker/2)
    lookup = Keyword.get(opts, :blocker_ref_lookup, &latest_ref/1)
    blockers = DispatchPolicy.non_terminal_blockers(issue, DispatchPolicy.terminal_state_set())

    with :ok <- subscribe(blockers, issue.identifier, subscriber, optimistic_blockers != []),
         {:ok, record} <- OptimisticStart.from_gate_evidence(optimistic_blockers, lookup) do
      {:ok, %{issue | optimistic_start: record}}
    end
  end

  defp subscribe(blockers, dependent, subscriber, optimistic?) do
    Enum.reduce_while(blockers, :ok, fn blocker, :ok ->
      case bind(blocker, dependent, subscriber) do
        :ok -> {:cont, :ok}
        error -> subscription_failure(error, dependent, optimistic?)
      end
    end)
  end

  defp bind(%{identifier: identifier}, dependent, subscriber)
       when is_binary(identifier) and identifier != "",
       do: subscriber.(dependent, identifier)

  defp bind(_blocker, _dependent, _subscriber), do: {:error, :blocker_identifier_unavailable}

  defp subscription_failure(error, dependent, optimistic?) do
    Logger.warning("Dispatch blocker subscription failed: issue_identifier=#{dependent} reason=#{inspect(error)}")
    if optimistic?, do: {:halt, {:error, :optimistic_subscription_failed}}, else: {:cont, :ok}
  end

  defp latest_ref(identifier) do
    BranchRefStore.latest(identifier)
  catch
    :exit, reason ->
      Logger.warning("Optimistic blocker ref unavailable: issue_identifier=#{identifier} reason=#{inspect(reason)}")
      nil
  end
end
