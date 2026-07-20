defmodule AiurWeb.BuildOrderViewModel.Edge do
  @moduledoc "One body-free blocker-to-blocked relationship."

  alias Aiur.BuildOrder.Diagnostic
  alias Aiur.TrackerIdentity

  @type t :: %__MODULE__{
          id: String.t(),
          source: TrackerIdentity.t() | nil,
          target: TrackerIdentity.t() | nil,
          source_key: term(),
          target_key: term(),
          kind: :native | :external | :unknown,
          state: Aiur.BuildOrder.EdgeState.t(),
          source_connection: :blocked_by | :blocking,
          url: String.t() | nil,
          text: String.t(),
          diagnostics: [Diagnostic.t()]
        }

  @enforce_keys [:id, :source_key, :target_key, :kind, :state, :source_connection, :text]
  defstruct [
    :id,
    :source,
    :target,
    :source_key,
    :target_key,
    :kind,
    :state,
    :source_connection,
    :url,
    :text,
    diagnostics: []
  ]
end

defmodule AiurWeb.BuildOrderViewModel.Node do
  @moduledoc "Joined planning, execution, and activity facts for one member."

  alias Aiur.BuildOrder.{Diagnostic, Icon}
  alias Aiur.TrackerIdentity

  @type t :: %__MODULE__{
          key: term(),
          identity: TrackerIdentity.t() | nil,
          title: String.t(),
          url: String.t() | nil,
          document_url: String.t() | nil,
          plan: map(),
          execution: map(),
          activity: map(),
          readiness: Aiur.BuildOrder.Readiness.t(),
          lane_icon: Icon.t(),
          status_icon: Icon.t(),
          health: map(),
          observed_at: map(),
          provenance: map(),
          diagnostics: [Diagnostic.t()],
          card: map()
        }

  @enforce_keys [
    :key,
    :identity,
    :title,
    :plan,
    :execution,
    :activity,
    :readiness,
    :lane_icon,
    :status_icon,
    :health,
    :observed_at,
    :provenance,
    :card
  ]
  defstruct [
    :key,
    :identity,
    :title,
    :url,
    :document_url,
    :plan,
    :execution,
    :activity,
    :readiness,
    :lane_icon,
    :status_icon,
    :health,
    :observed_at,
    :provenance,
    :card,
    diagnostics: []
  ]
end

defmodule AiurWeb.BuildOrderViewModel.Capability do
  @moduledoc "A normalized, identity-qualified read-only destination fact."

  alias Aiur.TrackerIdentity

  @type reason ::
          :identity_mismatch
          | :inactive
          | :invalid_destination
          | :missing
          | :not_available
          | :not_configured
          | :not_opened
          | :stale
          | :unauthorized
          | :unavailable
          | :unreadable
          | :unsupported

  @type t :: %__MODULE__{
          identity: TrackerIdentity.t() | nil,
          destination: String.t() | nil,
          number: pos_integer() | nil,
          label: String.t() | nil,
          reason: reason() | nil,
          available?: boolean(),
          active?: boolean() | nil,
          readable?: boolean() | nil
        }

  defstruct [:identity, :destination, :number, :label, :active?, :readable?, available?: false, reason: :unavailable]
end

defmodule AiurWeb.BuildOrderViewModel.Group do
  @moduledoc "A deterministic lane or phase grouping over visible nodes."

  @type t :: %__MODULE__{
          dimension: :lane | :phase,
          key: term(),
          label: String.t(),
          node_keys: [term()],
          count: non_neg_integer()
        }

  @enforce_keys [:dimension, :key, :label, :node_keys, :count]
  defstruct [:dimension, :key, :label, :node_keys, :count]
end

defmodule AiurWeb.BuildOrderViewModel.Relationships do
  @moduledoc "Read-only relationship context for the selected member."

  alias Aiur.BuildOrder.Diagnostic
  alias AiurWeb.BuildOrderViewModel.{Capability, Edge, Node}

  @type t :: %__MODULE__{
          selected: Node.t() | nil,
          blocked_by: [Edge.t()],
          blocking: [Edge.t()],
          external: [Edge.t()],
          capabilities: %{optional(atom()) => Capability.t()},
          diagnostics: [Diagnostic.t()],
          status: :selected | :not_found | :invalid_selection
        }

  defstruct selected: nil,
            blocked_by: [],
            blocking: [],
            external: [],
            capabilities: %{},
            diagnostics: [],
            status: :not_found
end

defmodule AiurWeb.BuildOrderViewModel do
  @moduledoc """
  Versioned, body-free read model for Build Order graph consumers.

  The model deliberately keeps planning, orchestrator execution, and event
  activity subrecords separate. Consumers must not reinterpret one as another.
  """

  alias Aiur.BuildOrder.{Diagnostic, ProviderHealth}
  alias AiurWeb.BuildOrderViewModel.{Edge, Group, Node, Relationships}

  @type status ::
          :ready
          | :empty
          | :structurally_invalid
          | :provider_stale
          | :provider_unavailable

  @type t :: %__MODULE__{
          version: pos_integer(),
          status: status(),
          root: map() | nil,
          nodes: [Node.t()],
          edges: [Edge.t()],
          lane_groups: [Group.t()],
          phase_groups: [Group.t()],
          relationships: Relationships.t(),
          adjacency: map(),
          reverse_adjacency: map(),
          strongly_connected_components: [list()],
          topological_order: list(),
          summary: map(),
          planning_health: ProviderHealth.t(),
          execution_health: :available | :unavailable,
          activity_health: :available | :unavailable,
          generations: map(),
          diagnostics: [Diagnostic.t()],
          planning?: boolean()
        }

  defstruct version: 1,
            status: :provider_unavailable,
            root: nil,
            nodes: [],
            edges: [],
            lane_groups: [],
            phase_groups: [],
            relationships: %Relationships{},
            adjacency: %{},
            reverse_adjacency: %{},
            strongly_connected_components: [],
            topological_order: [],
            summary: %{},
            planning_health: %ProviderHealth{},
            execution_health: :unavailable,
            activity_health: :unavailable,
            generations: %{planning: :unknown, activity: :unknown},
            diagnostics: [],
            planning?: false
end
