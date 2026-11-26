defmodule Aiur.PollCadence.Widen do
  @moduledoc "Poll interval widening shared by cadence and webhook policy."

  alias Aiur.Config

  @doc "The configured widen factor, floored at 1.0."
  @spec widen_factor(keyword()) :: float()
  def widen_factor(opts \\ []) do
    factor =
      Keyword.get_lazy(opts, :widen_factor, fn ->
        case Config.settings() do
          {:ok, settings} -> settings.webhooks.poll_widen_factor
          _error -> 1.0
        end
      end)

    case factor do
      number when is_number(number) and number > 1.0 -> number / 1
      _otherwise -> 1.0
    end
  end

  @doc "Widens an interval by a factor while preserving the original as a floor."
  @spec widen(pos_integer(), number()) :: pos_integer()
  def widen(base_ms, factor) when is_integer(base_ms) and base_ms > 0 and is_number(factor) do
    base_ms |> Kernel.*(factor) |> round() |> max(base_ms)
  end
end
