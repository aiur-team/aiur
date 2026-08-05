defmodule AiurWeb.OperatorControlCenter.ConversationDrawer.Presenter do
  @moduledoc """
  Pure presenter for the DASH-027 read-only conversation drawer.

  Turns one normalized DASH-026 `Aiur.LiveConversation` snapshot plus its Units
  row metadata into a render-ready view. It performs no I/O: it consumes only the
  already-sanitized public snapshot (no local paths, raw payloads, prompts,
  reasoning, credentials, or capability URLs are present in that projection) and
  the safe row facts. The drawer is a read-only mirror; the viewer never
  participates in the conversation.
  """

  alias Aiur.TrackerIdentity

  @participation_notice "Read-only mirror. You are viewing this conversation and are not participating in it."

  @typedoc "Drawer lifecycle beyond the snapshot state, owned by the LiveView."
  @type lifecycle :: :active | :superseded | :out_of_scope

  @spec present(map(), map() | nil, lifecycle(), map() | nil) :: map()
  def present(row, snapshot, lifecycle \\ :active, log \\ nil)

  def present(row, snapshot, lifecycle, log) when is_map(row) do
    snapshot = normalize_snapshot(snapshot)
    state = state_for(lifecycle, snapshot)
    messages = present_messages(snapshot.messages)

    %{
      heading: %{
        title: title(row),
        identity_label: identity_label(Map.get(row, :identity))
      },
      metadata: metadata(row, snapshot),
      state: state,
      state_label: state_label(state),
      state_detail: state_detail(state),
      live?: lifecycle == :active and snapshot.state == :live,
      health_label: health_label(snapshot.health),
      freshness_label: freshness_label(snapshot.freshness),
      observed_at: observed_at(snapshot.observed_at),
      messages: messages,
      message_count: length(messages),
      empty?: messages == [],
      truncated?: snapshot.truncated? or snapshot.evicted_count > 0,
      evicted_count: snapshot.evicted_count,
      truncation_note: truncation_note(snapshot),
      participation_notice: @participation_notice,
      log: present_log(log)
    }
  end

  @spec participation_notice() :: String.t()
  def participation_notice, do: @participation_notice

  defp normalize_snapshot(snapshot) when is_map(snapshot) do
    %{
      state: Map.get(snapshot, :state, :unavailable),
      health: Map.get(snapshot, :health, :unknown),
      freshness: Map.get(snapshot, :freshness, :unknown),
      messages: safe_messages(Map.get(snapshot, :messages)),
      observed_at: Map.get(snapshot, :observed_at),
      truncated?: Map.get(snapshot, :truncated?, false) == true,
      evicted_count: non_neg(Map.get(snapshot, :evicted_count)),
      source: Map.get(snapshot, :source)
    }
  end

  defp normalize_snapshot(_snapshot) do
    %{
      state: :unavailable,
      health: :unavailable,
      freshness: :unknown,
      messages: [],
      observed_at: nil,
      truncated?: false,
      evicted_count: 0,
      source: nil
    }
  end

  defp safe_messages(messages) when is_list(messages), do: messages
  defp safe_messages(_messages), do: []

  defp non_neg(value) when is_integer(value) and value >= 0, do: value
  defp non_neg(_value), do: 0

  # A superseded or out-of-scope drawer never adopts the live snapshot state:
  # its content is frozen and clearly attributed to the ended generation so a
  # replacement worker is never shown under the old heading.
  defp state_for(:superseded, _snapshot), do: :superseded
  defp state_for(:out_of_scope, _snapshot), do: :out_of_scope
  defp state_for(:active, snapshot), do: snapshot.state

  defp present_messages(messages) do
    messages
    |> Enum.map(&present_message/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&{message_sort_key(&1.occurred_at), &1.id})
  end

  # Agent-log entries (Aiur.AgentLog) are a simpler shape than conversation
  # messages: role/title/timestamp/body with no occurred_at. Present them as a
  # bounded, chronologically-ordered transcript so the drawer can render the
  # log beneath the conversation.
  defp present_log(nil), do: nil

  defp present_log(%{messages: messages}) when is_list(messages) do
    presented = messages |> Enum.map(&present_log_entry/1) |> Enum.reject(&is_nil/1)
    if presented == [], do: nil, else: presented
  end

  defp present_log(_log), do: nil

  defp present_log_entry(%{role: role, title: title, timestamp: timestamp, body: body})
       when is_binary(role) and is_binary(body) do
    %{
      id: log_entry_id(title, timestamp, body),
      role: role,
      role_label: role_label(role),
      title: entry_title(title, role),
      body: body,
      occurred_at: nil,
      observed_at: nil,
      timestamp: timestamp
    }
  end

  defp present_log_entry(_entry), do: nil

  defp log_entry_id(title, timestamp, body)
       when is_binary(title) and is_binary(timestamp) and is_binary(body),
       do: :crypto.hash(:sha256, title <> timestamp <> body) |> Base.encode16(case: :lower)

  defp log_entry_id(_title, _timestamp, _body), do: "log"

  defp entry_title(title, role) when is_binary(title) and title != "" and title != role, do: title
  defp entry_title(_title, role), do: role_label(role)

  defp present_message(%{id: id, role: role, body: body} = message)
       when is_binary(id) and is_binary(role) and is_binary(body) do
    %{
      id: id,
      role: role,
      role_label: role_label(role),
      title: message_title(message, role),
      body: body,
      occurred_at: datetime(Map.get(message, :occurred_at)),
      observed_at: datetime(Map.get(message, :observed_at))
    }
  end

  defp present_message(_message), do: nil

  defp message_title(%{title: title}, _role) when is_binary(title) and title != "", do: title
  defp message_title(_message, role), do: role_label(role)

  defp message_sort_key(%DateTime{} = occurred_at), do: DateTime.to_unix(occurred_at, :microsecond)
  defp message_sort_key(_occurred_at), do: 0

  defp role_label("agent"), do: "Agent"
  defp role_label("operator"), do: "Operator"
  defp role_label("tool"), do: "Tool summary"
  defp role_label(role) when is_binary(role), do: humanize(role)

  defp metadata(row, _snapshot) do
    [
      %{key: :agent, label: "Agent", value: known_label(Map.get(row, :agent_family))},
      %{key: :backend, label: "Backend", value: known_label(Map.get(row, :backend))},
      %{key: :requested_model, label: "Requested model", value: known(Map.get(row, :requested_model))},
      %{key: :resolved_model, label: "Resolved model", value: known(Map.get(row, :resolved_model))}
    ]
  end

  defp title(row) do
    case Map.get(row, :title) do
      title when is_binary(title) and title != "" -> title
      _title -> "Conversation"
    end
  end

  defp identity_label(%TrackerIdentity{owner: owner, repository: repository, identifier: identifier})
       when is_binary(owner) and is_binary(repository) and is_binary(identifier),
       do: "#{owner}/#{repository} ##{identifier}"

  defp identity_label(_identity), do: "Typed identity unavailable"

  defp state_label(:live), do: "Live"
  defp state_label(:ended), do: "Ended"
  defp state_label(:known_empty), do: "No messages yet"
  defp state_label(:stale), do: "Stale"
  defp state_label(:unavailable), do: "Unavailable"
  defp state_label(:restart_unknown), do: "Continuity unknown"
  defp state_label(:superseded), do: "Superseded"
  defp state_label(:out_of_scope), do: "Out of scope"
  defp state_label(_state), do: "Unknown"

  defp state_detail(:live), do: "This conversation is receiving live updates."
  defp state_detail(:ended), do: "This conversation has ended."
  defp state_detail(:known_empty), do: "No conversation has been recorded for this worker yet."
  defp state_detail(:stale), do: "The source is unavailable; showing the last known conversation."
  defp state_detail(:unavailable), do: "The conversation source is currently unavailable."

  defp state_detail(:restart_unknown),
    do: "Activity continuity is unknown after a projection restart."

  defp state_detail(:superseded),
    do: "A newer worker generation replaced this unit. This conversation has ended; reopen the action to view the current worker."

  defp state_detail(:out_of_scope),
    do: "This unit is no longer in the current catalog scope. This conversation has ended."

  defp state_detail(_state), do: "The conversation state is unknown."

  defp health_label(:healthy), do: "Healthy"
  defp health_label(:unavailable), do: "Unavailable"
  defp health_label(_health), do: "Unknown"

  defp freshness_label(:current), do: "Current"
  defp freshness_label(:stale), do: "Stale"
  defp freshness_label(_freshness), do: "Unknown"

  defp truncation_note(%{truncated?: true, evicted_count: count}) when count > 0,
    do: "Older messages are truncated. #{count} earlier #{message_word(count)} not shown."

  defp truncation_note(%{truncated?: true}),
    do: "Older messages are truncated to the newest bounded window."

  defp truncation_note(_snapshot), do: nil

  defp message_word(1), do: "message is"
  defp message_word(_count), do: "messages are"

  defp observed_at(%DateTime{} = value), do: value
  defp observed_at(_value), do: nil

  defp datetime(%DateTime{} = value), do: value
  defp datetime(_value), do: nil

  defp known(value) when is_binary(value) and value != "", do: value
  defp known(_value), do: "Unknown"

  defp known_label(value) when is_binary(value) and value != "", do: humanize(value)
  defp known_label(value) when is_atom(value) and not is_nil(value), do: humanize(value)
  defp known_label(_value), do: "Unknown"

  defp humanize(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
