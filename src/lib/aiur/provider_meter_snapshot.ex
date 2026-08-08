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
          last_source_version: non_neg_integer() | nil,
          last_attempt_at: DateTime.t() | nil,
          consecutive_failures: non_neg_integer()
        }

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          provider: atom() | nil,
          backend: atom() | nil,
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
            health: %{
              state: :unavailable,
              failure: :no_observation,
              last_observed_at: nil,
              last_source_version: nil,
              last_attempt_at: nil,
              consecutive_failures: 0
            },
            windows: %{}

  @spec empty(atom(), atom(), String.t()) :: t()
  def empty(provider, backend, generation) do
    %__MODULE__{
      provider: provider,
      backend: backend,
      provider_account_generation: generation,
      health: health(:no_observation)
    }
  end

  @spec unknown(atom(), atom()) :: t()
  def unknown(provider, backend) do
    %__MODULE__{
      provider: provider,
      backend: backend,
      health: %{
        state: :unavailable,
        failure: :unknown_account_generation,
        last_observed_at: nil,
        last_source_version: nil,
        last_attempt_at: nil,
        consecutive_failures: 0
      }
    }
  end

  defp health(failure) do
    %{
      state: :unavailable,
      failure: failure,
      last_observed_at: nil,
      last_source_version: nil,
      last_attempt_at: nil,
      consecutive_failures: 0
    }
  end
end
