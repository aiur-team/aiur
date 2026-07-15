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

defmodule Aiur.BuildOrder.TicketDetail.Snapshot do
  @moduledoc false

  alias Aiur.BuildOrder.Lifecycle
  alias Aiur.TrackerIdentity

  @type t :: %__MODULE__{
          identity: TrackerIdentity.t(),
          title: String.t(),
          description: String.t() | nil,
          lifecycle: Lifecycle.t(),
          url: String.t(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          observed_at: DateTime.t()
        }

  @enforce_keys [:identity, :title, :lifecycle, :url, :created_at, :updated_at, :observed_at]
  defstruct [:identity, :title, :description, :lifecycle, :url, :created_at, :updated_at, :observed_at]
end
