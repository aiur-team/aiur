defmodule Aiur.ExecutorEvents do
  @moduledoc """
  Durable, Executor-scoped events.

  The Exchange provides immediate fan-out, while this small journal and cursor
  store make an Executor restart safe. It deliberately has no ticket identity:
  an Executor is a run principal, not another managed ticket agent.
  """

  alias Aiur.Config.Paths
  alias Aiur.Decision
  alias Aiur.DecisionLog
  alias Aiur.Events.Exchange
  alias Aiur.Events.IdGenerator
  alias Aiur.Events.Publisher
  alias Aiur.Events.Topic
  alias Aiur.JSONSafe
  alias Aiur.JsonStore

  @default_topic "executor.#"

  @spec publish_deferred(Decision.t()) :: {:ok, pos_integer(), non_neg_integer()} | {:error, term()}
  def publish_deferred(%Decision{} = decision) do
    publish(
      "executor.decision.deferred",
      %{
        decision_id: decision.decision_id,
        issue_identifier: decision.ticket.identifier,
        title: decision.question,
        options: decision.options,
        context: decision.context,
        deferred_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        provenance: :operator_dashboard
      },
      source: :internal
    )
  end

  @spec publish(String.t(), map(), keyword()) :: {:ok, pos_integer(), non_neg_integer()} | {:error, term()}
  def publish(topic, payload, opts \\ []) when is_binary(topic) and is_map(payload) do
    source = Keyword.get(opts, :source, :executor_cli)

    with :ok <- validate_topic(topic),
         :ok <- reject_github_source(source),
         id when is_integer(id) <- IdGenerator.next_id(),
         event <- payload |> JSONSafe.normalize() |> Map.merge(%{"id" => id, "topic" => topic, "source" => source_name(source)}),
         :ok <- append_event(event) do
      Publisher.publish_persisted(topic, payload, id, source: source)
    end
  end

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic) when is_binary(topic) do
    with :ok <- validate_topic(topic) do
      state = subscription_state()
      subscriptions = Enum.uniq(state["subscribed_to"] ++ [topic])
      persist_subscription_state(%{state | "subscribed_to" => subscriptions})
    end
  end

  @spec unsubscribe(String.t()) :: :ok | {:error, term()}
  def unsubscribe(topic) when is_binary(topic) do
    with :ok <- validate_topic(topic) do
      state = subscription_state()
      persist_subscription_state(%{state | "subscribed_to" => Enum.reject(state["subscribed_to"], &(&1 == topic))})
    end
  end

  @spec subscriptions() :: [String.t()]
  def subscriptions, do: subscription_state()["subscribed_to"]

  @spec last_seen_event_id() :: non_neg_integer() | nil
  def last_seen_event_id, do: subscription_state()["last_seen_event_id"]

  @doc "Streams persisted missed events, then live Exchange events, as JSON lines until interrupted."
  @spec listen(keyword()) :: no_return()
  def listen(opts \\ []) do
    topic = Keyword.get(opts, :topic, @default_topic)
    :ok = subscribe(topic)
    patterns = subscriptions()

    try do
      Enum.each(patterns, &Exchange.subscribe/1)
      replay(patterns, last_seen_event_id()) |> Enum.each(&deliver/1)
      receive_events(patterns)
    after
      Enum.each(patterns, &safe_unsubscribe/1)
    end
  end

  @doc false
  @spec replay([String.t()], non_neg_integer() | nil) :: [map()]
  def replay(patterns, cursor) when is_list(patterns) do
    cursor = cursor || 0

    journal_events()
    |> Enum.filter(&(Map.get(&1, "id", 0) > cursor and matches_any?(patterns, Map.get(&1, "topic"))))
    |> Enum.sort_by(&Map.get(&1, "id", 0))
  end

  defp receive_events(patterns) do
    receive do
      {:event, event} ->
        topic = Map.get(event, :topic) || Map.get(event, "topic")

        if matches_any?(patterns, topic) do
          deliver(event)
        end

        receive_events(patterns)
    end
  end

  defp deliver(event) do
    id = Map.get(event, :id) || Map.get(event, "id")

    if not is_integer(id) or id > (last_seen_event_id() || 0) do
      IO.puts(Jason.encode!(event))
      advance_cursor(id)
    end
  end

  defp advance_cursor(id) when is_integer(id) do
    state = subscription_state()
    current = state["last_seen_event_id"] || 0
    persist_subscription_state(%{state | "last_seen_event_id" => max(current, id)})
  end

  defp advance_cursor(_id), do: :ok

  defp validate_topic(topic) do
    if String.trim(topic) == "" or String.starts_with?(topic, ".") or String.ends_with?(topic, ".") or String.contains?(topic, "..") do
      {:error, :invalid_topic}
    else
      :ok
    end
  end

  defp reject_github_source(source) when source in [:github, "github"], do: {:error, :executor_namespace_rejects_github_source}
  defp reject_github_source(%{kind: :github}), do: {:error, :executor_namespace_rejects_github_source}
  defp reject_github_source(%{"kind" => "github"}), do: {:error, :executor_namespace_rejects_github_source}
  defp reject_github_source(_source), do: :ok

  defp source_name(source) when is_atom(source), do: Atom.to_string(source)
  defp source_name(source), do: source

  defp replay_validator(%{"id" => id, "topic" => topic} = event) when is_integer(id) and is_binary(topic), do: {:ok, event}
  defp replay_validator(_event), do: {:error, :invalid_executor_event}

  defp journal_events do
    case DecisionLog.replay(journal_path(), &replay_validator/1) do
      {:ok, events, _corruption} -> events
      {:error, _reason} -> []
    end
  end

  defp append_event(event) do
    with :ok <- DecisionLog.prepare(Paths.log_root_dir(), journal_path()) do
      DecisionLog.append(journal_path(), event)
    end
  end

  defp subscription_state do
    case JsonStore.read(subscription_path()) do
      {:ok, %{} = state} ->
        %{
          "subscribed_to" => List.wrap(state["subscribed_to"]),
          "last_seen_event_id" => state["last_seen_event_id"]
        }

      _ ->
        %{"subscribed_to" => [], "last_seen_event_id" => nil}
    end
  end

  defp persist_subscription_state(state) do
    JsonStore.write!(subscription_path(), state)
    :ok
  rescue
    error -> {:error, {:subscription_store_unavailable, Exception.message(error)}}
  end

  defp matches_any?(patterns, topic) when is_binary(topic), do: Enum.any?(patterns, &Topic.matches?(&1, topic))
  defp matches_any?(_patterns, _topic), do: false

  defp safe_unsubscribe(topic) do
    Exchange.unsubscribe(topic)
  rescue
    _error -> :ok
  end

  defp journal_path, do: Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.executor.events.ndjson")
  defp subscription_path, do: Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.executor.subscriptions.json")
end
