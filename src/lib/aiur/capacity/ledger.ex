defmodule Aiur.Capacity.Ledger do
  @moduledoc """
  Capacity reservation ledger (#7890, plan `2026-11-08-7881` section 4).

  Readings lag dispatch: five claims inside one poll interval all see the same
  reading. The ledger records a *hold* for every claim the policy allows, in the
  same call that checks it (`claim/4`), so the next claim sees the reading minus
  the work already promised against it.

  Pure data: callers keep the struct, pass time in, and read verdicts out.

  ## Holds

  `%{ticket, backend, account, kind, estimate, rate, created_at}`.

    * `:window` (subscription accounts): `estimate` is percent of the binding
      window, `rate` the burn percent per agent-hour it was computed from.
    * `:usd` (metered and prepaid sources): `estimate` is USD; `account` is `nil`.

  An estimate may be `:unknown` (see `Aiur.Capacity.Ledger.Estimate`).

  ## Projected remaining

  The latest reading's remaining minus the open holds on that scope created
  *after* the reading was observed. A hold created before the reading is already
  inside it ("folded"). An unknown estimate makes the result `:unknown` on a
  fail-closed (reserved or limited) scope and subtracts nothing otherwise.

  ## Reconcile

  Every reconcile appends `%{ticket, backend, account, kind, estimate, actual, at}`
  to `reconciles` (newest first):

    * `observe_reading/4` folds each `:window` hold the reading now covers;
      `estimate` and `actual` are burn percent per agent-hour, `actual` the
      burn this reading showed (`:unknown` when it cannot be measured). A
      measured burn also updates the account's learned rate (EWMA).
    * `turn_ended/4` replaces a `:usd` hold's estimate with the recorded spend.
  """

  alias Aiur.Capacity.Ledger.Estimate

  @ewma_alpha 0.3
  @reconcile_keep 200

  @type kind :: :window | :usd
  @type amount :: number() | :unknown
  @type hold :: %{
          ticket: term(),
          backend: String.t(),
          account: String.t() | nil,
          kind: kind(),
          estimate: amount(),
          rate: amount() | nil,
          created_at: DateTime.t(),
          folded_at: DateTime.t() | nil
        }
  @type reading :: %{remaining: amount(), observed_at: DateTime.t() | nil}
  @type scope :: {String.t(), String.t() | nil} | :usd_total

  @type t :: %__MODULE__{
          holds: %{term() => hold()},
          readings: %{{String.t(), String.t()} => %{used_percent: number(), observed_at: DateTime.t()}},
          burn: %{{String.t(), String.t()} => float()},
          reconciles: [map()]
        }

  defstruct holds: %{}, readings: %{}, burn: %{}, reconciles: []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Checks `attrs` against `reading` and, when allowed, records its hold in the
  same step, so a second claim in the same poll interval sees the first.

  The check reads projected remaining *before* this claim, as the reserve rule
  does. Options: `:threshold` (default `0`): at or below it the claim holds
  with `:reason` (default `:reserve`); `:fail_closed` (default `false`): an
  unknown projection holds with `:reading_unknown` instead of allowing.
  """
  @spec claim(t(), map(), reading(), keyword()) :: {:allow, t()} | {{:hold, atom()}, t()}
  def claim(%__MODULE__{} = ledger, attrs, reading, opts \\ []) do
    fail_closed? = Keyword.get(opts, :fail_closed, false)
    candidate = new_hold(attrs)
    scope = {candidate.backend, candidate.account}

    case projected_remaining(ledger, scope, reading, fail_closed?) do
      :unknown when fail_closed? -> {{:hold, :reading_unknown}, ledger}
      :unknown -> {:allow, add(ledger, candidate)}
      projected -> verdict(ledger, candidate, projected, opts)
    end
  end

  defp verdict(ledger, candidate, projected, opts) do
    if projected <= Keyword.get(opts, :threshold, 0) do
      {{:hold, Keyword.get(opts, :reason, :reserve)}, ledger}
    else
      {:allow, add(ledger, candidate)}
    end
  end

  @doc "Records a hold without a check (rebuild, pins)."
  @spec hold(t(), map()) :: t()
  def hold(%__MODULE__{} = ledger, attrs), do: add(ledger, new_hold(attrs))

  @doc "Closes the hold of a stopped agent."
  @spec release(t(), term()) :: t()
  def release(%__MODULE__{} = ledger, ticket), do: %{ledger | holds: Map.delete(ledger.holds, ticket)}

  @doc """
  Rebuilds holds from running agents at start, so the ledger needs no state
  file. Each agent is a hold attrs map with `created_at` set to when it started;
  `estimate_fun` fills in its estimate.
  """
  @spec rebuild([map()], (map() -> {amount(), amount() | nil})) :: t()
  def rebuild(running, estimate_fun) when is_list(running) do
    Enum.reduce(running, new(), fn agent, ledger ->
      {estimate, rate} = estimate_fun.(agent)
      hold(ledger, Map.merge(agent, %{estimate: estimate, rate: rate}))
    end)
  end

  @doc "The latest reading minus the holds created after it. See the moduledoc."
  @spec projected_remaining(t(), scope(), reading(), boolean()) :: amount()
  def projected_remaining(_ledger, _scope, %{remaining: :unknown}, _fail_closed?), do: :unknown
  def projected_remaining(_ledger, _scope, %{observed_at: nil}, _fail_closed?), do: :unknown

  def projected_remaining(%__MODULE__{} = ledger, scope, %{remaining: remaining, observed_at: observed_at}, fail_closed?) do
    ledger.holds
    |> Map.values()
    |> Enum.filter(&(in_scope?(&1, scope) and DateTime.compare(&1.created_at, observed_at) == :gt))
    |> Enum.reduce_while(remaining, fn
      %{estimate: :unknown}, _acc when fail_closed? -> {:halt, :unknown}
      %{estimate: :unknown}, acc -> {:cont, acc}
      %{estimate: estimate}, acc -> {:cont, acc - estimate}
    end)
  end

  @doc """
  Folds a fresh reading for a subscription account: learns burn from the change
  in used percent over the agent-hours run on the account since the previous
  reading, and reconciles every `:window` hold the reading now covers.
  """
  @spec observe_reading(t(), String.t(), String.t(), %{used_percent: number(), observed_at: DateTime.t()}) :: t()
  def observe_reading(%__MODULE__{} = ledger, backend, account, %{used_percent: used, observed_at: at} = reading) do
    key = {backend, account}
    previous = Map.get(ledger.readings, key)
    holds = ledger.holds |> Map.values() |> Enum.filter(&(&1.kind == :window and in_scope?(&1, key)))
    actual = measured_burn(previous, used, at, holds)

    folded = Enum.filter(holds, &(&1.folded_at == nil and DateTime.compare(&1.created_at, at) != :gt))

    ledger =
      Enum.reduce(folded, ledger, fn hold, acc ->
        acc = reconcile(acc, hold, hold.rate || :unknown, actual, at)
        add(acc, %{hold | folded_at: at})
      end)

    %{ledger | readings: Map.put(ledger.readings, key, reading), burn: learn(ledger.burn, key, actual)}
  end

  @doc "Learned burn percent per agent-hour for an account, or `nil`."
  @spec learned_burn(t(), String.t(), String.t()) :: float() | nil
  def learned_burn(%__MODULE__{burn: burn}, backend, account), do: Map.get(burn, {backend, account})

  @doc "A turn ended: the `:usd` hold's estimate becomes the recorded spend."
  @spec turn_ended(t(), term(), amount(), DateTime.t()) :: t()
  def turn_ended(%__MODULE__{} = ledger, ticket, actual_usd, %DateTime{} = at) do
    case Map.get(ledger.holds, ticket) do
      %{kind: :usd} = hold ->
        ledger = reconcile(ledger, hold, hold.estimate, actual_usd, at)
        %{ledger | holds: Map.put(ledger.holds, ticket, %{hold | estimate: actual_usd})}

      _other ->
        ledger
    end
  end

  @doc """
  A hard USD limit crossed while an agent runs stops new turns on that source
  at the next turn boundary. Unknown spend under a limit stops too.
  """
  @spec stop_new_turns?(amount(), number() | nil) :: boolean()
  def stop_new_turns?(_spend, nil), do: false
  def stop_new_turns?(:unknown, _limit), do: true
  def stop_new_turns?(spend, limit), do: spend >= limit

  defdelegate window_estimate(learned_rate, default_rate, expected_hours), to: Estimate
  defdelegate usd_estimate(turn_costs, cost_bound), to: Estimate
  defdelegate period_spend(usage), to: Estimate

  defp new_hold(attrs) do
    attrs = Map.new(attrs)

    %{
      ticket: Map.fetch!(attrs, :ticket),
      backend: Map.fetch!(attrs, :backend),
      account: Map.get(attrs, :account),
      kind: Map.fetch!(attrs, :kind),
      estimate: Map.get(attrs, :estimate, :unknown),
      rate: Map.get(attrs, :rate),
      created_at: Map.fetch!(attrs, :created_at),
      folded_at: nil
    }
  end

  defp add(ledger, hold), do: %{ledger | holds: Map.put(ledger.holds, hold.ticket, hold)}

  defp in_scope?(%{kind: :usd}, :usd_total), do: true
  defp in_scope?(_hold, :usd_total), do: false
  defp in_scope?(%{kind: :usd, backend: backend}, {backend, _account}), do: true
  defp in_scope?(%{backend: backend, account: account}, {backend, account}), do: true
  defp in_scope?(_hold, _scope), do: false

  defp measured_burn(nil, _used, _at, _holds), do: :unknown

  defp measured_burn(%{used_percent: prev_used, observed_at: prev_at}, used, at, holds) do
    agent_hours = holds |> Enum.map(&overlap_hours(&1.created_at, prev_at, at)) |> Enum.sum()

    # A drop in used percent is a window reset, not negative burn.
    if agent_hours > 0 and used >= prev_used, do: (used - prev_used) / agent_hours, else: :unknown
  end

  defp overlap_hours(started_at, from, to) do
    start = if DateTime.compare(started_at, from) == :gt, do: started_at, else: from
    max(DateTime.diff(to, start, :second), 0) / 3600
  end

  defp learn(burn, _key, :unknown), do: burn
  defp learn(burn, key, actual), do: Map.update(burn, key, actual * 1.0, &(@ewma_alpha * actual + (1 - @ewma_alpha) * &1))

  defp reconcile(ledger, hold, estimate, actual, at) do
    entry = %{ticket: hold.ticket, backend: hold.backend, account: hold.account, kind: hold.kind, estimate: estimate, actual: actual, at: at}
    %{ledger | reconciles: Enum.take([entry | ledger.reconciles], @reconcile_keep)}
  end
end
