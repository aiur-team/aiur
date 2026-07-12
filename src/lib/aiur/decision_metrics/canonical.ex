defmodule Aiur.DecisionMetrics.Canonical do
  @moduledoc "Canonical Decision projection adapter for metrics recovery and legacy-attention correlation."

  require Logger

  alias Aiur.DecisionStore

  @doc "Builds a bounded redacted lifecycle seed and legacy-attention index."
  @spec snapshot(GenServer.server(), pos_integer()) :: %{events: [map()], attention_index: map()}
  def snapshot(server, limit) when is_integer(limit) and limit > 0 do
    decisions =
      server
      |> current_decisions()
      |> Enum.sort_by(&created_sort_key/1, :desc)
      |> Enum.take(limit)

    %{
      events: Enum.flat_map(decisions, &decision_events(&1, server)),
      attention_index: attention_index(decisions)
    }
  end

  defp current_decisions(server) do
    DecisionStore.list(server)
  rescue
    error ->
      Logger.warning("decision_metrics canonical_read_failed error=#{Exception.message(error)}")
      []
  catch
    :exit, reason ->
      Logger.warning("decision_metrics canonical_read_failed reason=#{inspect(reason)}")
      []
  end

  defp decision_events(decision, server) do
    identifier = decision |> field(:ticket) |> field(:identifier)

    [request_event(decision, identifier, server)] ++
      revision_events(decision, identifier) ++
      answer_events(decision, identifier) ++
      dispatch_events(decision, identifier) ++
      agent_fact_events(decision, identifier)
  end

  defp request_event(decision, identifier, server) do
    event(decision, identifier, :requested, "request", earliest_request_time(decision, server), %{
      blocking: field(decision, :blocking)
    })
  end

  defp earliest_request_time(decision, server) do
    case DecisionStore.history(field(decision, :decision_id), server) do
      {:ok, versions} -> Enum.reduce(versions, field(decision, :created_at), &earliest_created_at/2)
      {:error, :not_found} -> field(decision, :created_at)
    end
  end

  defp earliest_created_at(version, %DateTime{} = earliest) do
    case field(version, :created_at) do
      %DateTime{} = candidate -> if DateTime.before?(candidate, earliest), do: candidate, else: earliest
      _other -> earliest
    end
  end

  defp revision_events(decision, identifier) do
    case {field(decision, :version), field(decision, :legacy_attention)} do
      {version, nil} when is_integer(version) and version > 1 ->
        optional_event(decision, identifier, :revised, version, field(decision, :created_at))

      _other ->
        []
    end
  end

  defp answer_events(decision, identifier) do
    case field(decision, :answer) do
      answer when is_map(answer) ->
        optional_event(
          decision,
          identifier,
          :answer_recorded,
          field(answer, :action_id),
          field(answer, :accepted_at),
          %{actor: field(answer, :actor)}
        )

      _other ->
        []
    end
  end

  defp dispatch_events(decision, identifier) do
    decision
    |> field(:dispatch_attempts, [])
    |> Enum.flat_map(fn attempt ->
      token = field(attempt, :attempt_id)

      optional_event(decision, identifier, :dispatch_queued, token, field(attempt, :queued_at)) ++
        optional_event(decision, identifier, :delivered, token, field(attempt, :delivered_at))
    end)
  end

  defp agent_fact_events(decision, identifier) do
    fact_event(decision, identifier, :acknowledged, field(decision, :acknowledgement)) ++
      fact_event(decision, identifier, :resolved, field(decision, :resolution))
  end

  defp fact_event(decision, identifier, stage, fact) when is_map(fact) do
    optional_event(decision, identifier, stage, stage, field(fact, :occurred_at))
  end

  defp fact_event(_decision, _identifier, _stage, _fact), do: []

  defp optional_event(decision, identifier, stage, token, at, extra \\ %{})

  defp optional_event(decision, identifier, stage, token, %DateTime{} = at, extra) do
    [event(decision, identifier, stage, token, at, extra)]
  end

  defp optional_event(_decision, _identifier, _stage, _token, _at, _extra), do: []

  defp event(decision, identifier, stage, token, at, extra) do
    decision_id = field(decision, :decision_id)

    Map.merge(
      %{
        id: "canonical:#{stage}:#{decision_id}:#{token}",
        event_type: Atom.to_string(stage),
        topic: "ticket.#{identifier}.agent.decision.#{topic_slug(stage)}",
        decision_id: decision_id,
        occurred_at: at
      },
      extra
    )
  end

  defp topic_slug(:answer_recorded), do: "answered"
  defp topic_slug(:dispatch_queued), do: "queued"
  defp topic_slug(stage), do: Atom.to_string(stage)

  defp attention_index(decisions) do
    Enum.reduce(decisions, %{}, fn decision, index ->
      case field(decision, :legacy_attention) do
        attention when is_map(attention) ->
          case {field(attention, :topic), field(decision, :decision_id)} do
            {topic, decision_id} when is_binary(topic) and is_binary(decision_id) ->
              Map.put(index, topic, decision_id)

            _invalid ->
              index
          end

        _other ->
          index
      end
    end)
  end

  defp created_sort_key(decision) do
    case field(decision, :created_at) do
      %DateTime{} = created_at -> DateTime.to_unix(created_at, :microsecond)
      _other -> 0
    end
  end

  defp field(nil, _key), do: nil
  defp field(map, key), do: field(map, key, nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
