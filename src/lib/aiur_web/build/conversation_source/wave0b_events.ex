defmodule AiurWeb.Build.ConversationSource.Wave0bEvents do
  @moduledoc """
  Reads the facts the conversation's event rows are built from: the ticket's
  own event log, its history snapshot (progress percents), recent merges and
  open blocking Commands. Read only; every read that fails is reported as
  unavailable instead of empty.
  """

  alias Aiur.{AgentEventFeed, Commands, RecentMergeStore, SecretRedactor, TrackerIdentity}
  alias Aiur.BuildOrder.TicketHistoryProvider
  alias AiurWeb.Build.ConversationEvents
  alias AiurWeb.EndpointConfig

  @kinds [:self, :emit, :emit_alert]

  @spec read(map(), keyword()) :: {:ok, map()}
  def read(%{id: id} = ref, _opts) do
    identity = identity(ref)

    {:ok,
     %{
       identity: identity,
       log: safe(fn -> (EndpointConfig.get(:build_events_log_fun) || (&log/2)).(id, identity) end) |> redacted(),
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
    AgentEventFeed.ticket_events(id, identity, opts)
  end

  @doc "Subscribes the caller to the ticket's history updates; returns the topic to release later."
  @spec subscribe(TrackerIdentity.t()) :: {:ok, String.t()} | {:error, term()}
  def subscribe(identity) do
    topic = TicketHistoryProvider.topic(identity)
    with :ok <- Phoenix.PubSub.subscribe(Aiur.PubSub, topic), do: {:ok, topic}
  end

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic), do: Phoenix.PubSub.unsubscribe(Aiur.PubSub, topic)

  # Summaries are agent-written: valid UTF-8, secrets redacted, before any row is built from them.
  defp redacted({:ok, rows}), do: {:ok, Enum.map(rows, fn row -> Map.update(row, :summary, nil, &clean_summary/1) end)}
  defp redacted(result), do: result
  defp clean_summary(text) when is_binary(text), do: text |> AgentEventFeed.scrub() |> SecretRedactor.redact()
  defp clean_summary(other), do: other

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
    with {:ok, ids} <- Commands.open_blocking_decision_ids([id]) do
      {:ok, Enum.flat_map(ids, &decision/1)}
    end
  end

  # A question answered or gone between the two calls is skipped; an unreadable store makes the whole read unavailable.
  defp decision(id) do
    case Commands.get(id) do
      {:ok, %{decision: %{decision_status: :open} = decision}} -> [decision]
      {:ok, _closed} -> []
      {:error, :store_unavailable} -> exit(:store_unavailable)
      {:error, {:indeterminate, _health}} -> exit(:store_unavailable)
      {:error, _missing} -> []
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
