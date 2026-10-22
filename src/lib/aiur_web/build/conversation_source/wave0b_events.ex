defmodule AiurWeb.Build.ConversationSource.Wave0bEvents do
  @moduledoc """
  Reads the facts the conversation's event rows are built from: the ticket's
  own event log, its history snapshot (progress percents), recent merges and
  open blocking Commands. Read only; every read that fails is reported as
  unavailable instead of empty.
  """

  alias Aiur.{DecisionStore, IssueLog, RecentMergeStore, TrackerIdentity}
  alias Aiur.BuildOrder.TicketHistoryProvider
  alias Aiur.IssueLog.EventHistory
  alias AiurWeb.Build.ConversationEvents
  alias AiurWeb.EndpointConfig

  @kinds [:self, :emit, :emit_alert]

  @spec read(map(), keyword()) :: {:ok, map()}
  def read(%{id: id} = ref, _opts) do
    identity = identity(ref)

    {:ok,
     %{
       identity: identity,
       log: safe(fn -> (EndpointConfig.get(:build_events_log_fun) || (&log/2)).(id, identity) end),
       history: if(identity, do: safe(fn -> (EndpointConfig.get(:build_events_history_fun) || (&TicketHistoryProvider.request/1)).(identity) end), else: {:error, :no_identity}),
       merges: merges(),
       decisions: decisions(id),
       pause: get_in(ref, [:running, :pause_reason]),
       repository: repository(),
       read_at: System.system_time(:millisecond)
     }}
  end

  @doc "The ticket's event log: by tracker identity when it is joinable, else by the configured repository's identifier."
  @spec log(String.t(), TrackerIdentity.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def log(id, identity) do
    opts = [kinds: @kinds, limit: ConversationEvents.log_limit()]
    if identity, do: IssueLog.event_history(identity, opts), else: EventHistory.read_event_history(IssueLog.event_log_path(id), opts)
  end

  defp identity(ref) do
    identity = get_in(ref, [:running, :tracker_identity]) || ref[:identity]
    if TrackerIdentity.joinable?(identity), do: identity
  end

  defp merges do
    case safe(fn -> (EndpointConfig.get(:build_events_merges_fun) || fn -> RecentMergeStore.list() end).() end) do
      list when is_list(list) -> list
      _ -> :unavailable
    end
  end

  defp decisions(id) do
    fun = EndpointConfig.get(:build_events_decisions_fun) || (&open_decisions/1)

    case safe(fn -> fun.(id) end) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> :unavailable
    end
  end

  defp open_decisions(id) do
    with {:ok, ids} <- DecisionStore.open_blocking_decision_ids([id]) do
      {:ok, Enum.flat_map(ids, &decision/1)}
    end
  end

  # An answered question between the two calls is skipped; an exit here makes the whole read unavailable.
  defp decision(id) do
    case DecisionStore.get(id) do
      {:ok, decision} -> [decision]
      {:error, :not_found} -> []
    end
  end

  defp repository do
    case safe(fn -> Aiur.Tracker.workspace_repo_segment() end) do
      repo when is_binary(repo) -> repo
      _ -> nil
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end
