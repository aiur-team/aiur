defmodule Aiur.BuildOrder.TicketHistory.Failure do
  @moduledoc false

  @type kind :: :configuration | :invalid_identity | :repository_mismatch
  @type t :: %__MODULE__{kind: kind()}

  @enforce_keys [:kind]
  defstruct [:kind]
end

defmodule Aiur.BuildOrder.TicketHistory.Entry do
  @moduledoc false

  @type kind ::
          :agent_attention
          | :agent_decision
          | :agent_lifecycle
          | :branch
          | :continuous_integration
          | :issue
          | :phase
          | :progress
          | :pull_request

  @type source :: :exchange | :issue_log

  @type t :: %__MODULE__{
          event_id: pos_integer() | nil,
          kind: kind(),
          label: String.t(),
          source: source(),
          occurred_at: DateTime.t() | nil,
          observed_at: DateTime.t(),
          provenance: map(),
          details: map()
        }

  @enforce_keys [:kind, :label, :source, :observed_at]
  defstruct [:event_id, :kind, :label, :source, :occurred_at, :observed_at, provenance: %{}, details: %{}]
end

defmodule Aiur.BuildOrder.TicketHistory.Snapshot do
  @moduledoc false

  alias Aiur.BuildOrder.TicketHistory.Entry
  alias Aiur.TrackerIdentity

  @type health ::
          :available
          | :known_empty
          | :missing_source
          | :restart_unknown
          | :stale
          | :unavailable

  @type t :: %__MODULE__{
          identity: TrackerIdentity.t(),
          generation: pos_integer() | :unknown,
          health: health(),
          status_label: String.t(),
          progress: map(),
          latest_evidence: map(),
          entries: [Entry.t()],
          truncated?: boolean(),
          observed_at: DateTime.t() | nil,
          freshness: :fresh | :stale | :unknown,
          source_health: %{activity: atom(), history: atom()}
        }

  @enforce_keys [
    :identity,
    :generation,
    :health,
    :status_label,
    :progress,
    :latest_evidence,
    :entries,
    :truncated?,
    :freshness,
    :source_health
  ]
  defstruct [
    :identity,
    :generation,
    :health,
    :status_label,
    :progress,
    :latest_evidence,
    :observed_at,
    entries: [],
    truncated?: false,
    freshness: :unknown,
    source_health: %{activity: :missing_source, history: :missing_source}
  ]
end
