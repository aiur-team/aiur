defmodule Aiur.BuildOrder.TicketDetail.Failure do
  @moduledoc false

  @type kind ::
          :auth
          | :permission
          | :rate_limited
          | :timeout
          | :transport
          | :not_found
          | :schema
          | :validation
          | :provider_identity_mismatch
          | :nonfetchable_repository
          | :configuration
          | :capacity
          | :evicted

  @type t :: %__MODULE__{kind: kind(), retry_after: pos_integer() | nil}

  defstruct [:kind, retry_after: nil]
end

defmodule Aiur.BuildOrder.TicketDetail.State do
  @moduledoc false

  alias Aiur.BuildOrder.TicketDetail.{Failure, Snapshot}
  alias Aiur.TrackerIdentity

  @type health :: :healthy | :stale | :unavailable

  @type t :: %__MODULE__{
          identity: TrackerIdentity.t(),
          generation: pos_integer() | :unknown,
          health: health(),
          detail: Snapshot.t() | nil,
          failure: Failure.t() | nil,
          last_success_at: DateTime.t() | nil,
          last_attempt_at: DateTime.t() | nil
        }

  @enforce_keys [:identity, :generation, :health]
  defstruct [:identity, :generation, :health, :detail, :failure, :last_success_at, :last_attempt_at]
end

defmodule Aiur.BuildOrder.TicketDetail.IssueDestination do
  @moduledoc false

  @type t :: %__MODULE__{url: String.t()}

  @enforce_keys [:url]
  defstruct [:url]
end

defmodule Aiur.BuildOrder.TicketDetail.PullRequestDestination do
  @moduledoc false

  @type state :: :open | :closed | :merged

  @type t :: %__MODULE__{
          number: pos_integer(),
          url: String.t(),
          state: state(),
          draft?: boolean(),
          updated_at: DateTime.t()
        }

  @enforce_keys [:number, :url, :state, :draft?, :updated_at]
  defstruct [:number, :url, :state, :draft?, :updated_at]
end

defmodule Aiur.BuildOrder.TicketDetail.Destinations do
  @moduledoc false

  alias Aiur.BuildOrder.TicketDetail.{IssueDestination, PullRequestDestination}

  @type primary_pull_request :: PullRequestDestination.t() | :not_linked

  @type t :: %__MODULE__{
          issue: IssueDestination.t() | nil,
          pull_requests: [PullRequestDestination.t()],
          primary_pull_request: primary_pull_request(),
          pull_requests_truncated?: boolean()
        }

  @enforce_keys [:issue, :pull_requests, :primary_pull_request, :pull_requests_truncated?]
  defstruct [:issue, :pull_requests, :primary_pull_request, :pull_requests_truncated?]
end

defmodule Aiur.BuildOrder.TicketDetail.Snapshot do
  @moduledoc false

  alias Aiur.BuildOrder.Lifecycle
  alias Aiur.BuildOrder.TicketDetail.Destinations
  alias Aiur.TrackerIdentity

  @type t :: %__MODULE__{
          identity: TrackerIdentity.t(),
          title: String.t(),
          description: String.t() | nil,
          lifecycle: Lifecycle.t(),
          url: String.t(),
          destinations: Destinations.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          observed_at: DateTime.t()
        }

  @enforce_keys [:identity, :title, :lifecycle, :url, :created_at, :updated_at, :observed_at]
  defstruct [
    :identity,
    :title,
    :description,
    :lifecycle,
    :url,
    :destinations,
    :created_at,
    :updated_at,
    :observed_at
  ]
end
