defmodule AiurWeb.BuildOrder.TicketContextPresenter.Capability do
  @moduledoc false

  @type kind :: :github | :chat | :commands | :document

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
          event_id: pos_integer() | nil,
          kind: atom(),
          label: String.t(),
          source: :exchange | :issue_log,
          occurred_at: DateTime.t() | nil,
          observed_at: DateTime.t(),
          details: map()
        }

  @enforce_keys [:kind, :label, :source, :observed_at]
  defstruct [:event_id, :kind, :label, :source, :occurred_at, :observed_at, details: %{}]
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
          description_truncated?: boolean(),
          lifecycle: %{state: atom(), reason: atom()},
          detail: map(),
          history: map(),
          progress: map(),
          latest_evidence: map(),
          logs: %{entries: [LogEntry.t()], truncated?: boolean(), observed_at: DateTime.t() | nil},
          capabilities: [Capability.t()],
          dependencies: %{
            blocked_by: [%{identifier: String.t(), title: String.t()}],
            blocking: [%{identifier: String.t(), title: String.t()}]
          }
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
    capabilities: [],
    description_truncated?: false,
    dependencies: %{blocked_by: [], blocking: []}
  ]
end
