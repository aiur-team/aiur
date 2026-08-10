defmodule Aiur.Webhooks.DeliveryMode do
  @moduledoc """
  Pure per-repo state machine for how a repository's events reach Aiur.

  Aiur runs against repos it does not own. A repo may have no webhook because
  nobody has admin rights, because there is no public ingress, or because policy
  forbids it. Event delivery mode is therefore decided **per repo, at runtime**,
  and this module is the decision.

  ## The states

      never_configured ──configure(true)──▶ configured_unproven
             ▲                                      │
             │ configure(false)                     │ record_delivery
             │                                      ▼
             └──────────────────────────────  webhook_backed
                                                 │      ▲
                                        sweep    │      │ record_delivery
                                     (silence)   ▼      │
                                            degraded ───┘

  Only `record_delivery/3` can reach `:webhook_backed`. Configuration says a
  webhook is *expected*; it never says one *works*. A misconfigured secret, a
  revoked App install, and a dead tunnel all present as "configured but silent",
  and that is exactly the state where widening a poll interval would starve a
  repo of events entirely. So a configured-but-silent repo is a polling repo
  that happens to have a webhook configured.

  Degradation is automatic and reversible: silence past the threshold drops a
  proven repo back to full polling (the caller raises the operator alert), and
  a single resumed delivery restores webhook mode with no operator action.

  This module holds no clock and no process. Callers pass `now`, which keeps
  every transition directly testable; `Aiur.Webhooks.ModeRegistry` owns the
  timer, the storage, and the alerting.
  """

  @type state :: :never_configured | :configured_unproven | :webhook_backed | :degraded
  @type transport :: :webhook | :polling
  @type polling_reason :: :never_configured | :configured_unproven | :degraded_from_silence | nil
  @type transition :: :none | :proven | :recovered | :degraded | :configured | :unconfigured

  @type t :: %__MODULE__{
          repo: String.t(),
          state: state(),
          configured?: boolean(),
          last_delivery_at: DateTime.t() | nil,
          degraded_at: DateTime.t() | nil,
          delivery_count: non_neg_integer()
        }

  @enforce_keys [:repo]
  defstruct repo: nil,
            state: :never_configured,
            configured?: false,
            last_delivery_at: nil,
            degraded_at: nil,
            delivery_count: 0

  @doc """
  Builds the mode for `repo` (an `"owner/name"` string).

  Options:

    * `:configured?` — whether config *expects* a webhook for this repo.
      Defaults to `false`. A newly configured repo starts unproven, never
      webhook-backed.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(repo, opts \\ []) when is_binary(repo) do
    configured? = Keyword.get(opts, :configured?, false)

    %__MODULE__{
      repo: repo,
      configured?: configured?,
      state: if(configured?, do: :configured_unproven, else: :never_configured)
    }
  end

  @doc """
  Applies a configuration change.

  Turning configuration *on* only ever reaches `:configured_unproven` — proof
  comes from deliveries alone. Turning it *off* discards the proof, because a
  repo whose webhook has been removed cannot be webhook-backed.
  """
  @spec configure(t(), boolean()) :: {t(), transition()}
  def configure(%__MODULE__{configured?: configured?} = mode, configured?), do: {mode, :none}

  def configure(%__MODULE__{} = mode, true) do
    {%{mode | configured?: true, state: :configured_unproven}, :configured}
  end

  def configure(%__MODULE__{} = mode, false) do
    unconfigured = %{
      mode
      | configured?: false,
        state: :never_configured,
        last_delivery_at: nil,
        degraded_at: nil,
        delivery_count: 0
    }

    {unconfigured, :unconfigured}
  end

  @doc """
  Records one observed, verified webhook delivery at `at`.

  This is the only transition that proves a repo webhook-backed, so it also
  implies configuration: a repo cannot deliver without one. Out-of-order or
  duplicate timestamps never move `last_delivery_at` backwards.

  Returns the transition that occurred: `:proven` the first time the repo is
  proven, `:recovered` when it climbs back out of `:degraded`, `:none` for a
  steady-state delivery.
  """
  @spec record_delivery(t(), DateTime.t()) :: {t(), transition()}
  def record_delivery(%__MODULE__{} = mode, %DateTime{} = at) do
    transition =
      case mode.state do
        :webhook_backed -> :none
        :degraded -> :recovered
        _unproven -> :proven
      end

    delivered = %{
      mode
      | state: :webhook_backed,
        configured?: true,
        last_delivery_at: latest(mode.last_delivery_at, at),
        degraded_at: nil,
        delivery_count: mode.delivery_count + 1
    }

    {delivered, transition}
  end

  @doc """
  Degrades a webhook-backed repo that has been silent for longer than
  `threshold_ms`.

  Only `:webhook_backed` can degrade. A `:configured_unproven` repo is already
  polling at full rate, so silence there is unremarkable and must not raise an
  alert every sweep.
  """
  @spec sweep(t(), DateTime.t(), pos_integer()) :: {t(), transition()}
  def sweep(%__MODULE__{state: :webhook_backed, last_delivery_at: %DateTime{} = last} = mode, %DateTime{} = now, threshold_ms)
      when is_integer(threshold_ms) and threshold_ms > 0 do
    if DateTime.diff(now, last, :millisecond) > threshold_ms do
      {%{mode | state: :degraded, degraded_at: now}, :degraded}
    else
      {mode, :none}
    end
  end

  def sweep(%__MODULE__{} = mode, %DateTime{}, threshold_ms) when is_integer(threshold_ms) and threshold_ms > 0 do
    {mode, :none}
  end

  @doc """
  The transport a repo is currently served by.

  Consumers must never call this to decide behavior — it exists for interval
  policy and operator display only.
  """
  @spec transport(t()) :: transport()
  def transport(%__MODULE__{state: :webhook_backed}), do: :webhook
  def transport(%__MODULE__{}), do: :polling

  @doc "True when the repo is proven webhook-backed right now."
  @spec webhook_backed?(t()) :: boolean()
  def webhook_backed?(%__MODULE__{} = mode), do: transport(mode) == :webhook

  @doc """
  Why a repo is polling, or `nil` when it is webhook-backed.

  The three reasons are operationally distinct: never configured is a fact
  about the repo, configured-but-unproven is a setup that has not yet worked,
  and degraded-from-silence is a setup that worked and then stopped.
  """
  @spec polling_reason(t()) :: polling_reason()
  def polling_reason(%__MODULE__{state: :webhook_backed}), do: nil
  def polling_reason(%__MODULE__{state: :degraded}), do: :degraded_from_silence
  def polling_reason(%__MODULE__{state: :configured_unproven}), do: :configured_unproven
  def polling_reason(%__MODULE__{state: :never_configured}), do: :never_configured

  defp latest(nil, %DateTime{} = at), do: at

  defp latest(%DateTime{} = current, %DateTime{} = at) do
    if DateTime.compare(at, current) == :lt, do: current, else: at
  end
end
