defmodule Aiur.ProviderMeterSnapshot do
  @moduledoc """
  A redacted, versioned projection of one provider account's meter facts.

  The `provider_account_generation` is an opaque value issued by
  `Aiur.ProviderAccountGeneration`. It is deliberately the only account
  correlation value retained here.
  """

  @schema_version 1

  @type health :: %{
          state: :healthy | :partial | :stale | :unavailable,
          failure: atom() | nil,
          last_observed_at: DateTime.t() | nil,
          last_source_version: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          provider: atom() | nil,
          backend: :app_server | nil,
          provider_account_generation: String.t() | nil,
          projection_generation: non_neg_integer(),
          auth_mode: :subscription | :api_key | :unknown,
          plan: map() | nil,
          update_kind: :snapshot | :patch | :tombstone | :unknown,
          observed_at: DateTime.t() | nil,
          ingested_at: DateTime.t() | nil,
          source: atom() | nil,
          source_version: non_neg_integer(),
          full_snapshot_observed_at: DateTime.t() | nil,
          window_tombstones: %{String.t() => %{observed_at: DateTime.t(), source_version: non_neg_integer()}},
          freshness: :fresh | :partial | :stale | :unknown,
          health: health(),
          windows: %{String.t() => map()}
        }

  defstruct schema_version: @schema_version,
            provider: nil,
            backend: nil,
            provider_account_generation: nil,
            projection_generation: 0,
            auth_mode: :unknown,
            plan: nil,
            update_kind: :unknown,
            observed_at: nil,
            ingested_at: nil,
            source: nil,
            source_version: 0,
            full_snapshot_observed_at: nil,
            window_tombstones: %{},
            freshness: :unknown,
            health: %{state: :unavailable, failure: :no_observation, last_observed_at: nil, last_source_version: nil},
            windows: %{}

  @spec empty(atom(), :app_server, String.t()) :: t()
  def empty(provider, backend, generation) do
    %__MODULE__{
      provider: provider,
      backend: backend,
      provider_account_generation: generation,
      health: %{state: :unavailable, failure: :no_observation, last_observed_at: nil, last_source_version: nil}
    }
  end

  @spec unknown(atom(), :app_server) :: t()
  def unknown(provider, backend) do
    %__MODULE__{
      provider: provider,
      backend: backend,
      health: %{
        state: :unavailable,
        failure: :unknown_account_generation,
        last_observed_at: nil,
        last_source_version: nil
      }
    }
  end
end
