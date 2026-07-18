defmodule Aiur.UsageCompaction.Policy do
  @moduledoc false

  # Pure, configurable retention policy. It decides which contiguous prefix of
  # raw ledger positions is eligible to be compacted and retired, given the
  # current ledger head, the watermark already retired, and the raw storage
  # size. Two guarantees hold regardless of the chosen thresholds:
  #
  #   * a minimum retained raw recovery window (`min_retained_positions`) is
  #     never crossed — the most recent raw positions always stay replayable;
  #   * the eligible range only ever advances (never regresses below the
  #     watermark already retired) and is bounded per cycle by `retire_batch`,
  #     so one sweep can never retire the whole ledger in a single destructive
  #     step.
  #
  # Correctness of compaction does not depend on the numbers here: whatever the
  # thresholds, the range returned is a gapless prefix strictly below the
  # retained window, and the aggregate coverage committed for it is exact.

  @enforce_keys [:min_retained_positions, :max_retained_positions, :max_retained_bytes, :retire_batch]
  defstruct [:min_retained_positions, :max_retained_positions, :max_retained_bytes, :retire_batch]

  @type t :: %__MODULE__{
          min_retained_positions: non_neg_integer(),
          max_retained_positions: pos_integer() | :infinity,
          max_retained_bytes: pos_integer() | :infinity,
          retire_batch: pos_integer()
        }

  @type facts :: %{
          required(:latest_position) => non_neg_integer(),
          required(:retired_through) => non_neg_integer(),
          required(:raw_bytes) => non_neg_integer()
        }

  # Conservative defaults measured against the ledger's 16 MiB segment cap and
  # observed per-record size: keep a generous replay window, only compact once
  # raw grows well past a typical working set.
  @default_min_retained_positions 500
  @default_max_retained_positions 5_000
  @default_max_retained_bytes 8_388_608
  @default_retire_batch 1_000

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      min_retained_positions: non_neg(opts, :min_retained_positions, @default_min_retained_positions),
      max_retained_positions: pos_or_infinity(opts, :max_retained_positions, @default_max_retained_positions),
      max_retained_bytes: pos_or_infinity(opts, :max_retained_bytes, @default_max_retained_bytes),
      retire_batch: positive(opts, :retire_batch, @default_retire_batch)
    }
  end

  @doc """
  Returns `{:retire, first_position, last_position}` for the gapless prefix
  eligible to be compacted and retired this cycle, or `:noop` when nothing is
  eligible. `first_position` is always `retired_through + 1`; `last_position`
  never enters the minimum retained window and never exceeds `retire_batch`
  positions past the watermark.
  """
  @spec eligible_range(t(), facts()) :: {:retire, pos_integer(), pos_integer()} | :noop
  def eligible_range(%__MODULE__{} = policy, %{
        latest_position: latest,
        retired_through: retired,
        raw_bytes: raw_bytes
      })
      when is_integer(latest) and is_integer(retired) and is_integer(raw_bytes) and latest >= 0 and
             retired >= 0 and raw_bytes >= 0 do
    # The highest position we may ever retire keeps the minimum window intact.
    retirable_ceiling = latest - policy.min_retained_positions

    target =
      cond do
        over_bytes?(policy, raw_bytes) -> retirable_ceiling
        is_integer(policy.max_retained_positions) -> latest - policy.max_retained_positions
        true -> retired
      end

    watermark =
      target
      |> min(retirable_ceiling)
      |> min(retired + policy.retire_batch)
      |> max(retired)

    if watermark > retired, do: {:retire, retired + 1, watermark}, else: :noop
  end

  def eligible_range(%__MODULE__{}, _facts), do: :noop

  @doc "Stable human-readable retention policy facts for health/coverage reporting."
  @spec describe(t()) :: map()
  def describe(%__MODULE__{} = policy) do
    %{
      min_retained_positions: policy.min_retained_positions,
      max_retained_positions: policy.max_retained_positions,
      max_retained_bytes: policy.max_retained_bytes,
      retire_batch: policy.retire_batch
    }
  end

  defp over_bytes?(%__MODULE__{max_retained_bytes: :infinity}, _raw_bytes), do: false
  defp over_bytes?(%__MODULE__{max_retained_bytes: max}, raw_bytes), do: raw_bytes > max

  defp non_neg(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  defp positive(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp pos_or_infinity(opts, key, default) do
    case Keyword.get(opts, key, default) do
      :infinity -> :infinity
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
