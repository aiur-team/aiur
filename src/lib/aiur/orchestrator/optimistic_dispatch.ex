defmodule Aiur.Orchestrator.OptimisticDispatch do
  @moduledoc "Binds native blocker events and attaches evaluated start heads before dispatch."

  require Logger

  alias Aiur.BuildQueue.Hints
  alias Aiur.Events.BranchRefStore
  alias Aiur.{Issue, OptimisticStart}
  alias Aiur.Orchestrator.{AutoSubscriptions, DispatchPolicy, OptimisticLedger}
  alias Aiur.RunTelemetry.Lifecycle
  alias Aiur.StartTrigger.ProgressStore

  @spec prepare_for_dispatch(Issue.t(), keyword()) :: {:ok, Issue.t()} | {:error, atom()}
  def prepare_for_dispatch(%Issue{optimistic_start: %{}} = issue, _opts), do: {:ok, issue}

  def prepare_for_dispatch(issue, opts) do
    lookup = Keyword.get(opts, :blocker_ref_lookup, &latest_ref/1)

    evidence =
      Enum.map(DispatchPolicy.optimistic_blockers(issue), fn id ->
        blocker = Enum.find(issue.blocked_by, &(&1.id == id))
        identifier = Map.get(blocker, :identifier, id)
        progress = ProgressStore.lookup(id) || %{}
        head = lookup.(identifier) || %{}

        %{
          identifier: identifier,
          pr_number: Map.get(progress, :pr_number),
          head_ref: Map.get(progress, :head_ref) || Map.get(head, :ref),
          head_sha: Map.get(progress, :head_sha) || Map.get(head, :sha)
        }
      end)

    prepare(issue, evidence, opts)
  end

  @spec prepare(Issue.t(), [map()], keyword()) :: {:ok, Issue.t()} | {:error, atom()}
  def prepare(%Issue{} = issue, optimistic_blockers, opts) do
    subscriber = Keyword.get(opts, :blocker_subscriber, &AutoSubscriptions.subscribe_for_declared_blocker/2)
    lookup = Keyword.get(opts, :blocker_ref_lookup, &latest_ref/1)
    terminal = DispatchPolicy.terminal_state_set()
    blockers = Enum.reject(issue.blocked_by, &DispatchPolicy.terminal_issue_state?(Map.get(&1, :state), terminal))

    with :ok <- subscribe(blockers, issue.identifier, subscriber, optimistic_blockers != []),
         {:ok, record} <- OptimisticStart.from_gate_evidence(optimistic_blockers, lookup) do
      {:ok, %{issue | optimistic_start: record}}
    end
  end

  @spec record(Aiur.Issue.t(), String.t(), [String.t()]) :: :ok
  def record(%{optimistic_start: nil}, _attempt_id, _ids), do: :ok

  def record(issue, attempt_id, _ids) do
    start = issue.optimistic_start

    blockers =
      Enum.map(start.blockers, fn head ->
        blocker = Enum.find(issue.blocked_by, &(Map.get(&1, :identifier, &1.id) == head.identifier))
        facts = if blocker, do: ProgressStore.lookup(blocker.id) || %{}, else: %{}

        %{
          "id" => head.identifier,
          "pr_number" => head.pr_number,
          "pr_head_sha_at_start" => head.sha,
          "pr_head_ref_at_start" => head.ref,
          "last_head_sha" => head.sha,
          "pr_state" => pr_state(facts),
          "failed_cause" => nil,
          "failed_at_ms" => nil,
          "merged_at_ms" => nil
        }
      end)

    trigger = Hints.trigger_for(issue.id)
    attrs = %{attempt_id: attempt_id, start_trigger: trigger, started_at_ms: DateTime.to_unix(start.started_at, :millisecond), blockers: blockers}

    case OptimisticLedger.record_start(issue.identifier, attrs) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Optimistic start not persisted ticket=#{issue.identifier} attempt=#{attempt_id} reason=#{inspect(reason)}")
    end

    Lifecycle.record(issue.identifier, attempt_id, :optimistic_start, :point, %{
      start_trigger: trigger,
      blockers: Enum.map(blockers, & &1["id"]),
      blocker_prs: Enum.map(blockers, & &1["pr_number"])
    })

    :ok
  end

  defp pr_state(%{stage: :pr_merged}), do: "merged"
  defp pr_state(%{closed_unmerged?: true}), do: "closed"
  defp pr_state(%{stage: stage}) when stage in [:pr_opened, :pr_ci_green, :pr_approved], do: "open"
  defp pr_state(_), do: nil

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
