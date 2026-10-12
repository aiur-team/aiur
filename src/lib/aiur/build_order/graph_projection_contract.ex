defmodule Aiur.BuildOrder.GraphProjection.Failure do
  @moduledoc "Safe planning-projection failure classification."

  @type kind ::
          :capacity
          | :configuration
          | :invalid_root
          | :provider_identity_mismatch
          | :provider_unavailable

  @type t :: %__MODULE__{kind: kind()}

  @enforce_keys [:kind]
  defstruct [:kind]
end

defmodule Aiur.BuildOrder.GraphProjection.Snapshot do
  @moduledoc "Immutable catalog or selected-root projection state."

  alias Aiur.BuildOrder.{Catalog, ProviderHealth, SelectedRoot}
  alias Aiur.TrackerIdentity

  @type scope :: :catalog | {:selected, TrackerIdentity.t()}
  @type data :: Catalog.t() | SelectedRoot.t() | nil
  @type authority_epoch :: pos_integer() | :unknown
  @type t :: %__MODULE__{
          scope: scope(),
          repository: TrackerIdentity.repository() | :unknown,
          authority_epoch: authority_epoch(),
          generation: pos_integer() | :unknown,
          data: data(),
          health: ProviderHealth.t(),
          membership_health: ProviderHealth.t() | nil,
          status_health: ProviderHealth.t() | nil,
          github_health: ProviderHealth.t() | nil,
          pack_overlay?: boolean()
        }

  @enforce_keys [:scope, :repository, :generation, :health]
  defstruct [:scope, :repository, :generation, :data, :health, :membership_health, :status_health, :github_health, pack_overlay?: false, authority_epoch: :unknown]
end
