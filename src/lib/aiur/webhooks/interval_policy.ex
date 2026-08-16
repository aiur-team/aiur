defmodule Aiur.Webhooks.IntervalPolicy do
  @moduledoc """
  Decides the poll interval for one repo from its delivery mode.

  The invariant this module exists to protect: **a repo that is not proven
  webhook-backed gets the base interval, unchanged, always.** Never configured,
  configured but never delivered, degraded from silence — all three poll exactly
  as they did before webhooks existed. Widening the interval for a repo that is
  receiving nothing is the failure this epic must not produce, so the rule is
  enforced here rather than trusted to each caller.

  The widen factor defaults to `1.0`, so mode detection on its own changes no
  interval anywhere. Turning that dial up is the cutover's decision, not this
  layer's, and the factor may never drop below `1.0` — webhook mode can only
  ever slow polling down.
  """

  alias Aiur.Config
  alias Aiur.Webhooks

  @doc """
  Returns the poll interval in milliseconds for `repo` given `base_ms`.

  Options:

    * `:transport` — skip the registry lookup and decide from a known transport
    * `:widen_factor` — override the configured factor
    * `:server` — registry to consult
  """
  @spec poll_interval_ms(pos_integer(), String.t(), keyword()) :: pos_integer()
  def poll_interval_ms(base_ms, repo, opts \\ []) when is_integer(base_ms) and base_ms > 0 and is_binary(repo) do
    case Keyword.get_lazy(opts, :transport, fn -> Webhooks.transport(repo, opts) end) do
      :webhook -> widen(base_ms, widen_factor(opts))
      _polling -> base_ms
    end
  end

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
