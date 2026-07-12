defmodule Aiur.DecisionHistory do
  @moduledoc """
  Read-only operator history projected from `Aiur.DecisionStore` records.

  The store remains the only source of truth. This module gives dashboard and
  API consumers one bounded, newest-first shape while preserving uncertainty:
  actor types are used only when a canonical record states them explicitly.
  OCC-1 request records have source-agent metadata but no separate mutation
  actor, so they are identified as ticket-agent activity rather than guessed to
  be human or supervising-agent decisions.
  """

  alias Aiur.DecisionStore

  @default_limit 50
  @actor_types %{
    "human" => :human_operator,
    "human_operator" => :human_operator,
    "operator" => :human_operator,
    "supervisor" => :supervising_agent,
    "supervising_agent" => :supervising_agent,
    "ticket_agent" => :ticket_agent,
    "agent" => :ticket_agent,
    "system" => :system
  }
  @change_kinds %{
    "requested" => :requested,
    "enriched" => :enriched,
    "answered" => :answered,
    "revised" => :revised,
    "superseded" => :superseded,
    "acknowledged" => :acknowledged,
    "resolved" => :resolved,
    "revision_recorded" => :revised,
    "revision_dispatched" => :revised,
    "revision_no_longer_applicable" => :revised,
    "follow_up_required" => :follow_up_required,
    "follow_up_handled" => :follow_up_handled
  }

  @spec list(keyword()) :: [map()]
  def list(opts \\ []) when is_list(opts) do
    server = Keyword.get(opts, :server, DecisionStore)
    history_fun = Keyword.get(opts, :history_fun, fn -> DecisionStore.all_history(server) end)

    history_fun.()
    |> from_histories(opts)
  end

  @doc "Projects an already-read Decision history map without another store call."
  @spec from_histories(map(), keyword()) :: [map()]
  def from_histories(histories, opts \\ []) when is_map(histories) and is_list(opts) do
    histories
    |> Map.values()
    |> List.flatten()
    |> Enum.map(&project_record/1)
    |> Enum.sort_by(&sort_key/1, :desc)
    |> Enum.take(limit(opts))
  end

  @doc "Projects one canonical history record into the operator-facing shape."
  @spec project_record(map()) :: map()
  def project_record(record) when is_map(record) do
    answer = map_value(record, :answer)
    revision = map_value(record, :revision) || revision_record(record)
    revision_answer = map_value(revision, :answer)
    follow_up = map_value(record, :follow_up)
    version = source_version(record, answer, revision)
    revision_of = first_value([value(record, :revision_of), value(revision, :prior_action_id)])
    follow_up_payload = follow_up(record, follow_up)
    change = change_kind(record, version, answer, revision, follow_up_payload)

    %{
      decision_id: value(record, :decision_id),
      ticket: ticket(value(record, :ticket)),
      question: value(record, :question),
      source_version: version,
      changed_at: changed_at(record, answer, revision, follow_up),
      change: change,
      actor: actor(record, answer, revision),
      action_id: first_value([value(record, :action_id), value(revision, :action_id), value(answer, :action_id)]),
      prior_action_id: first_value([value(record, :prior_action_id), value(revision, :prior_action_id)]),
      revision_sequence: first_value([value(record, :revision_sequence), value(revision, :sequence)]),
      revision_result: first_value([value(record, :revision_result), value(revision, :result)]),
      choice: choice(record, answer, revision_answer),
      rationale: first_value([value(record, :rationale), value(revision, :reason), value(answer, :rationale)]),
      dispatch_result: value(record, :dispatch_result),
      acknowledgement_result: value(record, :acknowledgement_result),
      revision_of: revision_of,
      superseded_by: value(record, :superseded_by),
      follow_up: follow_up_payload,
      revised?: change == :revised or not is_nil(revision_of)
    }
  end

  defp actor(record, answer, revision) do
    revision_answer = map_value(revision, :answer)

    case first_value([value(record, :actor), value(answer, :actor), value(revision_answer, :actor)]) do
      actor when is_map(actor) -> explicit_actor(actor)
      _other -> source_actor(value(record, :source))
    end
  end

  defp explicit_actor(actor) do
    type = normalize_actor_type(value(actor, :type))
    id = present(value(actor, :id))
    label = present(value(actor, :label)) || id || actor_type_label(type)
    %{type: type, id: id, label: label}
  end

  defp source_actor(source) when is_map(source) do
    case present(value(source, :agent_id)) do
      nil -> unknown_actor()
      agent_id -> %{type: :ticket_agent, id: agent_id, label: agent_id}
    end
  end

  defp source_actor(_source), do: unknown_actor()

  defp unknown_actor, do: %{type: :unknown, id: nil, label: "Unknown source"}

  defp normalize_actor_type(type) when is_atom(type), do: normalize_actor_type(Atom.to_string(type))

  defp normalize_actor_type(type) when is_binary(type) do
    Map.get(@actor_types, String.downcase(type), :unknown)
  end

  defp normalize_actor_type(_type), do: :unknown

  defp actor_type_label(:human_operator), do: "Human operator"
  defp actor_type_label(:supervising_agent), do: "Supervising agent"
  defp actor_type_label(:ticket_agent), do: "Ticket agent"
  defp actor_type_label(:system), do: "System"
  defp actor_type_label(:unknown), do: "Unknown source"

  defp change_kind(record, version, answer, revision, follow_up) do
    case first_value([value(record, :change_kind), value(record, :event_kind)]) do
      nil when follow_up.handled? -> :follow_up_handled
      nil when follow_up.required? -> :follow_up_required
      nil when is_map(revision) -> :revised
      nil when is_map(answer) -> :answered
      nil when version == 1 -> :requested
      nil when is_integer(version) -> :enriched
      nil -> :unknown
      kind -> normalize_change_kind(kind)
    end
  end

  defp normalize_change_kind(kind) when is_atom(kind), do: kind

  defp normalize_change_kind(kind) when is_binary(kind) do
    Map.get(@change_kinds, String.downcase(kind), :unknown)
  end

  defp normalize_change_kind(_kind), do: :unknown

  defp ticket(ticket) when is_map(ticket) do
    %{
      identifier: value(ticket, :identifier),
      title: value(ticket, :title),
      url: safe_url(value(ticket, :url))
    }
  end

  defp ticket(_ticket), do: %{identifier: nil, title: nil, url: nil}

  defp changed_at(record, answer, revision, follow_up) do
    [
      value(record, :recorded_at),
      value(record, :accepted_at),
      value(revision, :recorded_at),
      value(answer, :accepted_at),
      value(record, :follow_up_handled_at),
      value(follow_up, :handled_at),
      value(record, :follow_up_required_at),
      value(follow_up, :required_at),
      value(follow_up, :recorded_at),
      value(record, :timestamp),
      value(record, :created_at)
    ]
    |> first_value()
    |> timestamp()
  end

  defp choice(record, answer, revision_answer) do
    first_value([
      value(record, :choice),
      value(answer, :choice),
      value(answer, :option_id),
      value(answer, :custom_response),
      value(answer, :response),
      value(revision_answer, :choice),
      value(revision_answer, :option_id),
      value(revision_answer, :custom_response),
      value(revision_answer, :response)
    ])
  end

  defp source_version(record, answer, revision) do
    first_value([
      value(record, :version),
      value(record, :decision_version),
      value(answer, :decision_version),
      value(revision, :decision_version)
    ])
  end

  defp follow_up(record, follow_up) do
    %{
      required?: truthy?(first_value([value(record, :follow_up_required), value(follow_up, :required)])),
      handled?: truthy?(first_value([value(record, :follow_up_handled), value(follow_up, :handled)])),
      slug: first_value([value(record, :follow_up_slug), value(follow_up, :slug)]),
      required_at: timestamp(first_value([value(record, :follow_up_required_at), value(follow_up, :required_at)])),
      handled_at: timestamp(first_value([value(record, :follow_up_handled_at), value(follow_up, :handled_at)]))
    }
  end

  defp revision_record(record) do
    if not is_nil(value(record, :prior_action_id)) and is_integer(value(record, :sequence)),
      do: record,
      else: nil
  end

  defp map_value(map, key) do
    case value(map, key) do
      value when is_map(value) -> value
      _other -> nil
    end
  end

  defp first_value(values) when is_list(values), do: Enum.find(values, &(not is_nil(&1)))

  defp truthy?(value), do: value == true

  defp safe_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
         uri.userinfo in [nil, ""] do
      url
    end
  end

  defp safe_url(_url), do: nil

  defp timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp timestamp(timestamp) when is_binary(timestamp), do: timestamp
  defp timestamp(_timestamp), do: nil

  defp sort_key(entry) do
    {
      timestamp_key(entry.changed_at),
      integer(entry.source_version),
      present(entry.decision_id) || "",
      present(entry.action_id) || ""
    }
  end

  defp timestamp_key(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      _other -> 0
    end
  end

  defp timestamp_key(_timestamp), do: 0

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: 0

  defp limit(opts) do
    case Keyword.get(opts, :limit, @default_limit) do
      limit when is_integer(limit) and limit >= 0 -> limit
      _other -> @default_limit
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp value(_map, _key), do: nil
end
