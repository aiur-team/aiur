defmodule AiurWeb.BuildOrder.TicketContextPresenter.Capability do
  @moduledoc false

  @type kind :: :github | :chat | :commands

  @type t :: %__MODULE__{
          kind: kind(),
          variant: :issue | :pull_request | nil,
          number: pos_integer() | nil,
          label: String.t(),
          href: String.t() | nil,
          available?: boolean(),
          reason: String.t() | nil,
          external?: boolean()
        }

  @enforce_keys [:kind, :label, :available?, :external?]
  defstruct [:kind, :variant, :number, :label, :href, :reason, available?: false, external?: false]
end

defmodule AiurWeb.BuildOrder.TicketContextPresenter.LogEntry do
  @moduledoc false

  @type t :: %__MODULE__{
          kind: atom(),
          label: String.t(),
          source: :exchange | :issue_log,
          occurred_at: DateTime.t() | nil,
          observed_at: DateTime.t()
        }

  @enforce_keys [:kind, :label, :source, :observed_at]
  defstruct [:kind, :label, :source, :occurred_at, :observed_at]
end

defmodule AiurWeb.BuildOrder.TicketContextPresenter.View do
  @moduledoc false

  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.TicketContextPresenter.{Capability, LogEntry}

  @type t :: %__MODULE__{
          identity: TrackerIdentity.t() | nil,
          repository: String.t(),
          identifier: String.t() | nil,
          title: String.t(),
          description: String.t() | nil,
          lifecycle: %{state: atom(), reason: atom()},
          detail: map(),
          history: map(),
          progress: map(),
          latest_evidence: map(),
          logs: %{entries: [LogEntry.t()], truncated?: boolean(), observed_at: DateTime.t() | nil},
          capabilities: [Capability.t()]
        }

  @enforce_keys [
    :identity,
    :repository,
    :identifier,
    :title,
    :description,
    :lifecycle,
    :detail,
    :history,
    :progress,
    :latest_evidence,
    :logs,
    :capabilities
  ]
  defstruct [
    :identity,
    :repository,
    :identifier,
    :title,
    :description,
    :lifecycle,
    :detail,
    :history,
    :progress,
    :latest_evidence,
    :logs,
    capabilities: []
  ]
end

defmodule AiurWeb.BuildOrder.TicketContextPresenter do
  @moduledoc """
  Pure, bounded presentation data for one configured-repository ticket.

  This module only accepts BO-016 and BO-019 normalized snapshots. It never
  reads provider, process, log, or filesystem state; callers refresh those
  snapshots before asking the component to render.
  """

  alias Aiur.BuildOrder.{Bounded, Lifecycle, TicketHistory}
  alias Aiur.BuildOrder.TicketDetail.{Sanitizer, Snapshot, State}
  alias Aiur.BuildOrder.TicketHistory.Entry
  alias Aiur.{OpaqueIdentifier, TrackerIdentity}
  alias AiurWeb.BuildOrder.TicketContextPresenter.{Capability, LogEntry, View}

  @max_description_bytes 4_000
  @max_title_bytes 512
  @max_logs 100
  @max_capabilities 4
  @history_states [:available, :known_empty, :missing_source, :restart_unknown, :stale, :unavailable]
  @phase_labels [
    "Brainstorm started",
    "Brainstorm completed",
    "Plan started",
    "Plan completed",
    "Work started",
    "Work completed",
    "Review started",
    "Review completed"
  ]

  @type capability_input :: %{
          required(:kind) => Capability.kind(),
          optional(:variant) => :issue | :pull_request,
          optional(:number) => pos_integer(),
          required(:available?) => boolean(),
          optional(:href) => String.t(),
          optional(:reason) => :not_available | :not_configured | :not_opened | :unsupported
        }

  @spec max_description_bytes() :: pos_integer()
  def max_description_bytes, do: @max_description_bytes

  @spec max_logs() :: pos_integer()
  def max_logs, do: @max_logs

  @spec present(State.t(), TicketHistory.Snapshot.t(), [capability_input()]) :: View.t()
  def present(detail, history, capabilities \\ [])

  def present(%State{} = detail, %TicketHistory.Snapshot{} = history, capabilities) when is_list(capabilities) do
    identity = configured_identity(detail.identity)
    history_matches? = same_identity?(identity, history.identity)
    detail = detail_view(detail, identity)

    %View{
      identity: identity,
      repository: repository_label(identity),
      identifier: identifier(identity),
      title: detail.title,
      description: detail.description,
      lifecycle: detail.lifecycle,
      detail: Map.take(detail, [:state, :observed_at, :last_success_at, :last_attempt_at]),
      history: history_view(history, history_matches?),
      progress: progress_view(history, history_matches?),
      latest_evidence: latest_evidence_view(history, history_matches?),
      logs: logs_view(history, history_matches?),
      capabilities: normalize_capabilities(capabilities, identity)
    }
    |> normalize_view()
  end

  def present(_detail, _history, _capabilities) do
    unavailable_view()
  end

  defp detail_view(%State{} = state, identity) do
    snapshot = valid_snapshot(state.detail, identity)

    state_name =
      case {state.health, snapshot} do
        {:healthy, %Snapshot{}} -> :available
        {:stale, %Snapshot{}} -> :stale
        {:healthy, nil} -> :missing
        _ -> :unavailable
      end

    %{
      state: state_name,
      title: snapshot_title(snapshot, identity),
      description: snapshot_description(snapshot),
      lifecycle: snapshot_lifecycle(snapshot),
      observed_at: snapshot_observed_at(snapshot),
      last_success_at: datetime(state.last_success_at),
      last_attempt_at: datetime(state.last_attempt_at)
    }
  end

  defp valid_snapshot(%Snapshot{identity: snapshot_identity} = snapshot, identity) do
    if same_identity?(identity, snapshot_identity), do: snapshot
  end

  defp valid_snapshot(_snapshot, _identity), do: nil

  defp snapshot_title(%Snapshot{title: title}, identity), do: safe_title(title, identity)
  defp snapshot_title(_snapshot, identity), do: fallback_title(identity)

  defp snapshot_description(%Snapshot{description: description}), do: safe_description(description)
  defp snapshot_description(_snapshot), do: nil

  defp snapshot_lifecycle(%Snapshot{lifecycle: %Lifecycle{} = lifecycle}) do
    %{state: lifecycle_state(lifecycle.state), reason: lifecycle_reason(lifecycle.state_reason)}
  end

  defp snapshot_lifecycle(_snapshot), do: %{state: :unknown, reason: :unknown}

  defp lifecycle_state(state) when state in [:open, :closed], do: state
  defp lifecycle_state(_state), do: :unknown
  defp lifecycle_reason(reason) when reason in [:completed, :not_planned, :duplicate, :reopened, :none], do: reason
  defp lifecycle_reason(_reason), do: :unknown
  defp snapshot_observed_at(%Snapshot{observed_at: observed_at}), do: datetime(observed_at)
  defp snapshot_observed_at(_snapshot), do: nil

  defp history_view(%TicketHistory.Snapshot{} = history, true) do
    %{
      state: history_state(history.health),
      freshness: freshness(history.freshness),
      observed_at: datetime(history.observed_at),
      source_health: source_health(history.source_health)
    }
  end

  defp history_view(_history, _matches?) do
    %{state: :unavailable, freshness: :unknown, observed_at: nil, source_health: unavailable_source_health()}
  end

  defp progress_view(%TicketHistory.Snapshot{progress: progress}, true) when is_map(progress) do
    %{
      status: map_value(progress, :status, [:known, :unknown], :unknown),
      percent: percent(map_value(progress, :percent)),
      source: map_value(progress, :source, [:checkin, :phase], nil),
      occurred_at: datetime(map_value(progress, :occurred_at)),
      observed_at: datetime(map_value(progress, :observed_at)),
      provenance: provenance(map_value(progress, :provenance))
    }
  end

  defp progress_view(_history, _matches?),
    do: %{status: :unknown, percent: nil, source: nil, occurred_at: nil, observed_at: nil, provenance: %{}}

  defp latest_evidence_view(%TicketHistory.Snapshot{latest_evidence: evidence}, true) when is_map(evidence) do
    %{
      status: map_value(evidence, :status, [:known, :unknown], :unknown),
      source: evidence_source(map_value(evidence, :source)),
      occurred_at: datetime(map_value(evidence, :occurred_at)),
      observed_at: datetime(map_value(evidence, :observed_at)),
      provenance: provenance(map_value(evidence, :provenance))
    }
  end

  defp latest_evidence_view(_history, _matches?),
    do: %{status: :unknown, source: nil, occurred_at: nil, observed_at: nil, provenance: %{}}

  defp logs_view(%TicketHistory.Snapshot{} = history, true) do
    entries = history.entries |> List.wrap() |> Enum.flat_map(&log_entry/1)

    %{
      entries: Enum.take(entries, @max_logs),
      truncated?: history.truncated? == true or length(entries) > @max_logs,
      observed_at: datetime(history.observed_at)
    }
  end

  defp logs_view(_history, _matches?), do: %{entries: [], truncated?: false, observed_at: nil}

  defp log_entry(%Entry{} = entry) do
    normalized_log_entry(
      entry.kind,
      entry.source,
      entry.label,
      entry.occurred_at,
      entry.observed_at
    )
  end

  defp log_entry(_entry), do: []

  defp normalized_log_entry(kind, source, label, occurred_at, observed_at)
       when kind in [
              :agent_attention,
              :agent_decision,
              :agent_lifecycle,
              :branch,
              :continuous_integration,
              :issue,
              :phase,
              :progress,
              :pull_request
            ] and
              source in [:exchange, :issue_log] and is_struct(observed_at, DateTime) do
    [
      %LogEntry{
        kind: kind,
        label: log_label(kind, label),
        source: source,
        occurred_at: datetime(occurred_at),
        observed_at: observed_at
      }
    ]
  end

  defp normalized_log_entry(_kind, _source, _label, _occurred_at, _observed_at), do: []

  defp log_label(:agent_attention, _label), do: "Agent attention updated"
  defp log_label(:agent_decision, _label), do: "Agent decision updated"
  defp log_label(:agent_lifecycle, _label), do: "Agent state updated"
  defp log_label(:branch, _label), do: "Branch updated"
  defp log_label(:continuous_integration, _label), do: "Continuous integration updated"
  defp log_label(:issue, _label), do: "Issue updated"
  defp log_label(:progress, _label), do: "Progress updated"
  defp log_label(:pull_request, _label), do: "Pull request updated"
  defp log_label(:phase, label) when label in @phase_labels, do: label
  defp log_label(:phase, _label), do: "Phase updated"

  @doc false
  @spec normalize_capabilities([map()], TrackerIdentity.t() | nil) :: [Capability.t()]
  def normalize_capabilities(capabilities, identity) when is_list(capabilities) do
    {normalized, _seen} =
      Enum.reduce(capabilities, {[], MapSet.new()}, fn capability, {result, seen} ->
        add_capability(normalize_capability(capability, identity), result, seen)
      end)

    Enum.reverse(normalized)
  end

  def normalize_capabilities(_capabilities, _identity), do: []

  defp add_capability(nil, result, seen), do: {result, seen}

  defp add_capability(%Capability{} = capability, result, seen) do
    key = {capability.kind, capability.label}

    if MapSet.member?(seen, key) or length(result) == @max_capabilities do
      {result, seen}
    else
      {[capability | result], MapSet.put(seen, key)}
    end
  end

  @doc false
  @spec normalize_view(View.t() | term()) :: View.t()
  def normalize_view(%View{} = view) do
    identity = configured_identity(view.identity)

    %View{
      identity: identity,
      repository: repository_label(identity),
      identifier: identifier(identity),
      title: safe_title(view.title, identity),
      description: safe_description(view.description),
      lifecycle: normalized_lifecycle(view.lifecycle),
      detail: normalized_detail(view.detail),
      history: normalized_history(view.history),
      progress: normalized_progress(view.progress),
      latest_evidence: normalized_evidence(view.latest_evidence),
      logs: normalized_logs(view.logs),
      capabilities: normalize_capabilities(view.capabilities, identity)
    }
  end

  def normalize_view(_view), do: unavailable_view()

  defp normalized_lifecycle(lifecycle) when is_map(lifecycle) do
    %{
      state: lifecycle_state(map_value(lifecycle, :state)),
      reason: lifecycle_reason(map_value(lifecycle, :reason))
    }
  end

  defp normalized_lifecycle(_lifecycle), do: %{state: :unknown, reason: :unknown}

  defp normalized_detail(detail) when is_map(detail) do
    %{
      state: map_value(detail, :state, [:available, :stale, :missing, :unavailable], :unavailable),
      observed_at: datetime(map_value(detail, :observed_at)),
      last_success_at: datetime(map_value(detail, :last_success_at)),
      last_attempt_at: datetime(map_value(detail, :last_attempt_at))
    }
  end

  defp normalized_detail(_detail) do
    %{state: :unavailable, observed_at: nil, last_success_at: nil, last_attempt_at: nil}
  end

  defp normalized_history(history) when is_map(history) do
    %{
      state: history_state(map_value(history, :state)),
      freshness: freshness(map_value(history, :freshness)),
      observed_at: datetime(map_value(history, :observed_at)),
      source_health: source_health(map_value(history, :source_health))
    }
  end

  defp normalized_history(_history) do
    %{state: :unavailable, freshness: :unknown, observed_at: nil, source_health: unavailable_source_health()}
  end

  defp normalized_progress(progress) when is_map(progress) do
    %{
      status: map_value(progress, :status, [:known, :unknown], :unknown),
      percent: percent(map_value(progress, :percent)),
      source: map_value(progress, :source, [:checkin, :phase], nil),
      occurred_at: datetime(map_value(progress, :occurred_at)),
      observed_at: datetime(map_value(progress, :observed_at)),
      provenance: provenance(map_value(progress, :provenance))
    }
  end

  defp normalized_progress(_progress),
    do: %{status: :unknown, percent: nil, source: nil, occurred_at: nil, observed_at: nil, provenance: %{}}

  defp normalized_evidence(evidence) when is_map(evidence) do
    %{
      status: map_value(evidence, :status, [:known, :unknown], :unknown),
      source: evidence_source(map_value(evidence, :source)),
      occurred_at: datetime(map_value(evidence, :occurred_at)),
      observed_at: datetime(map_value(evidence, :observed_at)),
      provenance: provenance(map_value(evidence, :provenance))
    }
  end

  defp normalized_evidence(_evidence),
    do: %{status: :unknown, source: nil, occurred_at: nil, observed_at: nil, provenance: %{}}

  defp normalized_logs(logs) when is_map(logs) do
    entries = logs |> map_value(:entries) |> List.wrap() |> Enum.flat_map(&normalized_view_log_entry/1)

    %{
      entries: Enum.take(entries, @max_logs),
      truncated?: map_value(logs, :truncated?) == true or length(entries) > @max_logs,
      observed_at: datetime(map_value(logs, :observed_at))
    }
  end

  defp normalized_logs(_logs), do: %{entries: [], truncated?: false, observed_at: nil}

  defp normalized_view_log_entry(%LogEntry{} = entry),
    do:
      normalized_log_entry(
        entry.kind,
        entry.source,
        entry.label,
        entry.occurred_at,
        entry.observed_at
      )

  defp normalized_view_log_entry(_entry), do: []

  defp normalize_capability(capability, identity) when is_map(capability) do
    kind = map_value(capability, :kind, [:github, :chat, :commands], nil)
    variant = map_value(capability, :variant, [:issue, :pull_request], nil)

    case {kind, capability_label(kind, variant)} do
      {nil, _label} -> nil
      {_kind, nil} -> nil
      {kind, label} -> capability_from_availability(kind, variant, label, capability, identity)
    end
  end

  defp normalize_capability(_capability, _identity), do: nil

  defp capability_from_availability(kind, variant, label, capability, identity) do
    available? = map_value(capability, :available?) == true
    number = positive_integer(map_value(capability, :number))

    case available_href(
           kind,
           map_value(capability, :variant),
           map_value(capability, :href),
           identity,
           capability
         ) do
      {:ok, href, external?} when available? ->
        %Capability{
          kind: kind,
          variant: variant,
          number: number,
          label: label,
          href: href,
          available?: true,
          external?: external?
        }

      _ ->
        %Capability{
          kind: kind,
          variant: variant,
          number: number,
          label: label,
          available?: false,
          external?: false,
          reason: unavailable_reason(label, map_value(capability, :reason))
        }
    end
  end

  defp capability_label(:github, :issue), do: "Issue"
  defp capability_label(:github, :pull_request), do: "Pull request"
  defp capability_label(:github, nil), do: "GitHub"
  defp capability_label(:chat, _variant), do: "Chat"
  defp capability_label(:commands, _variant), do: "Commands"
  defp capability_label(_kind, _variant), do: nil

  defp available_href(:github, :issue, href, identity, _capability) do
    with {:ok, href} <- Bounded.github_issue_url_for(href, identity), do: {:ok, href, true}
  end

  defp available_href(:github, :pull_request, href, identity, capability) do
    with {:ok, href} <-
           Bounded.github_pull_request_url_for(href, identity, map_value(capability, :number)) do
      {:ok, href, true}
    end
  end

  defp available_href(kind, _variant, href, _identity, _capability) when kind in [:chat, :commands] do
    with {:ok, href} <- Bounded.relative_route(href), do: {:ok, href, false}
  end

  defp available_href(_kind, _variant, _href, _identity, _capability), do: :error

  defp unavailable_reason("Pull request", :not_opened), do: "Pull request has not been opened."
  defp unavailable_reason("Pull request", "Pull request has not been opened."), do: "Pull request has not been opened."
  defp unavailable_reason("Commands", _reason), do: "Commands are unavailable."
  defp unavailable_reason(label, _reason), do: "#{label} is unavailable."

  defp configured_identity(%TrackerIdentity{} = identity) do
    if safe_repository_identity?(identity) and TrackerIdentity.joinable?(identity), do: identity
  end

  defp configured_identity(_identity), do: nil

  defp same_identity?(%TrackerIdentity{} = left, %TrackerIdentity{} = right) do
    case {TrackerIdentity.github_key(left), TrackerIdentity.github_key(right)} do
      {nil, _right} -> false
      {left, left} -> true
      _different -> false
    end
  end

  defp same_identity?(_left, _right), do: false

  defp repository_label(%TrackerIdentity{owner: owner, repository: repository}), do: "#{owner}/#{repository}"
  defp repository_label(_identity), do: "Configured repository"
  defp identifier(%TrackerIdentity{identifier: identifier}) when is_binary(identifier), do: identifier
  defp identifier(_identity), do: nil

  defp history_state(state) when state in @history_states, do: state
  defp history_state(_state), do: :unavailable
  defp freshness(value) when value in [:fresh, :stale, :unknown], do: value
  defp freshness(_value), do: :unknown

  defp source_health(source_health) when is_map(source_health) do
    %{
      activity: map_value(source_health, :activity, @history_states, :unavailable),
      history: map_value(source_health, :history, @history_states, :unavailable)
    }
  end

  defp source_health(_source_health), do: unavailable_source_health()
  defp unavailable_source_health, do: %{activity: :unavailable, history: :unavailable}
  defp percent(value) when is_integer(value) and value in 0..100, do: value
  defp percent(_value), do: nil
  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp evidence_source(%{kind: kind, name: name}) when kind in [:agent_event, :agent_alert, :legacy] and is_binary(name) do
    case OpaqueIdentifier.normalize(name) do
      nil -> nil
      safe_name -> %{kind: kind, name: safe_name}
    end
  end

  defp evidence_source(_source), do: nil

  defp provenance(provenance) when is_map(provenance) do
    Enum.reduce([:run_id, :attempt, :session_id, :source_event_id], %{}, fn key, result ->
      case map_value(provenance, key) do
        value when is_integer(value) and value >= 0 -> Map.put(result, key, value)
        value when is_binary(value) -> maybe_put_safe_opaque(result, key, value)
        _ -> result
      end
    end)
  end

  defp provenance(_provenance), do: %{}

  defp map_value(map, key, allowed \\ nil, fallback \\ nil)

  defp map_value(map, key, allowed, fallback) when is_map(map) and is_list(allowed) do
    value = Map.get(map, key, Map.get(map, Atom.to_string(key)))
    if value in allowed, do: value, else: fallback
  end

  defp map_value(map, key, nil, _fallback) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp map_value(_map, _key, _allowed, fallback), do: fallback

  defp datetime(%DateTime{} = value), do: value
  defp datetime(_value), do: nil

  defp safe_title(value, identity) do
    case safe_text(value, @max_title_bytes) do
      {:ok, ""} -> fallback_title(identity)
      {:ok, title} -> title
      :error -> fallback_title(identity)
    end
  end

  defp fallback_title(nil), do: "Ticket context unavailable"
  defp fallback_title(identity), do: "Ticket #{identifier(identity) || "context"}"

  defp safe_description(nil), do: nil

  defp safe_description(value) do
    case safe_text(value, @max_description_bytes) do
      {:ok, ""} -> nil
      {:ok, description} -> description
      :error -> nil
    end
  end

  defp safe_text(value, limit) when is_binary(value) do
    case Sanitizer.sanitize(value, limit) do
      {:ok, value} -> {:ok, String.trim(value)}
      :error -> :error
    end
  end

  defp safe_text(_value, _limit), do: :error

  defp safe_repository_identity?(%TrackerIdentity{owner: owner, repository: repository, identifier: identifier}) do
    with {:ok, _repository} <- Bounded.github_repository_components(owner, repository),
         {:ok, _identifier} <- Bounded.github_issue_identifier(identifier) do
      true
    else
      _ -> false
    end
  end

  defp maybe_put_safe_opaque(map, key, value) do
    case OpaqueIdentifier.normalize(value) do
      nil -> map
      safe -> Map.put(map, key, safe)
    end
  end

  defp unavailable_view do
    %View{
      identity: nil,
      repository: "Configured repository",
      identifier: nil,
      title: "Ticket context unavailable",
      description: nil,
      lifecycle: %{state: :unknown, reason: :unknown},
      detail: %{state: :unavailable, observed_at: nil, last_success_at: nil, last_attempt_at: nil},
      history: %{
        state: :unavailable,
        freshness: :unknown,
        observed_at: nil,
        source_health: unavailable_source_health()
      },
      progress: %{status: :unknown, percent: nil, source: nil, occurred_at: nil, observed_at: nil, provenance: %{}},
      latest_evidence: %{status: :unknown, source: nil, occurred_at: nil, observed_at: nil, provenance: %{}},
      logs: %{entries: [], truncated?: false, observed_at: nil},
      capabilities: []
    }
  end
end
