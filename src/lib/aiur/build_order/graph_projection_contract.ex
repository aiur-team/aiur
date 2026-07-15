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
  @type t :: %__MODULE__{
          scope: scope(),
          repository: TrackerIdentity.repository() | :unknown,
          generation: pos_integer() | :unknown,
          data: data(),
          health: ProviderHealth.t()
        }

  @enforce_keys [:scope, :repository, :generation, :health]
  defstruct [:scope, :repository, :generation, :data, :health]
end
