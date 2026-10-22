defmodule Aiur.Webhooks.DeliveryLogCeiling do
  @moduledoc false

  @default_low_watermark 0.9

  @spec low_watermark(keyword()) :: float()
  def low_watermark(opts) do
    case Keyword.get(opts, :eviction_low_watermark, @default_low_watermark) do
      value when is_float(value) and value > 0 and value < 1 -> value
      _other -> @default_low_watermark
    end
  end

  @spec target(pos_integer(), float()) :: pos_integer()
  def target(max_entries, low_watermark), do: max(1, trunc(max_entries * low_watermark))
end
