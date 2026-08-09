defmodule Aiur.DecisionMetrics.Options do
  @moduledoc false

  @spec positive(keyword(), atom(), pos_integer()) :: pos_integer()
  def positive(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end
end
