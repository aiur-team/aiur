defmodule Aiur.Capacity.Policy do
  @moduledoc """
  Pure capacity policy decision (#7888, plan `2026-11-08-7881-provider-capacity-policy.md` §1 and §5).

  Given the expanded dispatch candidates (route x account), each with its
  reading, the open holds, the period spend and the effective `capacity`
  policy, `decide/3` returns one verdict per candidate:

    * `:allow`
    * `{:hold, reason}` — the candidate may not take this work now
    * `{:defer, :last_resort}` — allowed only when no other candidate is

  It reads no config, no process state and no files: callers pass everything.

  ## Rules, in order

    1. **Hard limits.** A source with a `limits.<period>_usd` set is held when
       its spend for that period has reached the limit (`limit_daily`,
       `limit_weekly`, `limit_monthly`) or is unknown (`spend_unknown`). The
       machine-wide `limits` apply to metered and prepaid sources
       (`limit_global`). Without a limit, unknown spend allows.
    2. **Reserve.** A reserved account whose projected remaining (the reading's
       tightest window minus its open holds) is at or below the reserve is held
       (`reserve`). An unknown or stale reading, or a hold with an unknown
       estimate, holds it too (`reading_unknown`): unknown never counts as
       headroom on a reserved account.
    3. **Floor.** `Aiur.Accounts.UsageFloor`, unchanged (`floor`).
    4. **Last resort.** A `last_resort: true` source is deferred while any
       other candidate is allowed, and allowed when none is.
    5. **Capability.** A source whose `serves` list omits the work kind is held
       (`not_served`).

  With an empty policy every candidate today's floor allows is `:allow`.

  ## Inputs

  The policy is the effective `capacity` map: `%{sources: %{backend =>
  source}, limits: %{daily_usd:, weekly_usd:, monthly_usd:}}`, where a source
  may carry `billing`, `last_resort`, `serves`, `reserve: %{percent:,
  accounts:}` (`accounts: nil` covers every account) and `limits`.

  A candidate is a map with `:route` (backend), `:account` and `:reading` (the
  `Aiur.Accounts.UsageFloor` reading shape); other keys pass through untouched.

  Options:

    * `:holds` — open holds newer than their account's reading, each
      `%{route:, account:, estimate_percent: number | nil}`
    * `:spend` — USD spent per period: `%{backend => %{daily_usd:, ...},
      global: %{daily_usd:, ...}}`; a missing or `nil` figure is unknown
    * `:floor_percent` — the usage floor that applies (default: none)
    * `:kind` — the work kind (default `:coding`)
  """

  alias Aiur.Accounts.UsageFloor

  @periods [daily_usd: :limit_daily, weekly_usd: :limit_weekly, monthly_usd: :limit_monthly]
  @billed ["metered", "prepaid"]

  @type reason ::
          :limit_daily
          | :limit_weekly
          | :limit_monthly
          | :limit_global
          | :spend_unknown
          | :reserve
          | :reading_unknown
          | :floor
          | :not_served
  @type verdict :: :allow | {:hold, reason()} | {:defer, :last_resort}
  @type candidate :: %{required(:route) => String.t(), optional(atom()) => term()}

  @doc "One `{candidate, verdict}` per candidate, in input order."
  @spec decide([candidate()], map(), keyword()) :: [{candidate(), verdict()}]
  def decide(candidates, policy, opts \\ []) when is_list(candidates) and is_map(policy) do
    verdicts = Enum.map(candidates, &{&1, verdict(&1, policy, opts)})
    others_allowed? = Enum.any?(verdicts, &match?({_candidate, :allow}, &1))

    Enum.map(verdicts, fn
      {candidate, :last_resort} when others_allowed? -> {candidate, {:defer, :last_resort}}
      {candidate, :last_resort} -> {candidate, :allow}
      pair -> pair
    end)
  end

  defp verdict(candidate, policy, opts) do
    source = source(policy, candidate.route)

    with :ok <- limits(source, policy, candidate.route, Keyword.get(opts, :spend, %{})),
         :ok <- reserve(source, candidate, Keyword.get(opts, :holds, [])),
         :ok <- floor(candidate, Keyword.get(opts, :floor_percent)),
         :ok <- serves(source, Keyword.get(opts, :kind, :coding)) do
      if Map.get(source, :last_resort) == true, do: :last_resort, else: :allow
    end
  end

  defp source(policy, route) do
    Map.get(Map.get(policy, :sources) || %{}, route) || %{}
  end

  defp limits(source, policy, route, spend) do
    with :ok <- period_limits(Map.get(source, :limits), Map.get(spend, route), nil) do
      if to_string(Map.get(source, :billing)) in @billed,
        do: period_limits(Map.get(policy, :limits), Map.get(spend, :global), :limit_global),
        else: :ok
    end
  end

  defp period_limits(limits, spent, reason) when is_map(limits) do
    Enum.find_value(@periods, :ok, fn {period, period_reason} ->
      case {Map.get(limits, period), spent && Map.get(spent, period)} do
        {limit, _spent} when not is_number(limit) -> nil
        {_limit, spent} when not is_number(spent) -> {:hold, :spend_unknown}
        {limit, spent} when spent >= limit -> {:hold, reason || period_reason}
        _within -> nil
      end
    end)
  end

  defp period_limits(_limits, _spent, _reason), do: :ok

  defp reserve(source, candidate, holds) do
    reserve = Map.get(source, :reserve) || %{}
    percent = Map.get(reserve, :percent) || 0
    accounts = Map.get(reserve, :accounts)

    cond do
      percent <= 0 -> :ok
      is_list(accounts) and Map.get(candidate, :account) not in accounts -> :ok
      true -> reserve_decision(projected(candidate, holds), percent)
    end
  end

  defp reserve_decision(nil, _percent), do: {:hold, :reading_unknown}
  defp reserve_decision(projected, percent) when projected <= percent, do: {:hold, :reserve}
  defp reserve_decision(_projected, _percent), do: :ok

  defp projected(candidate, holds) do
    reading = Map.get(candidate, :reading)

    estimates =
      for %{route: route, account: account} = hold <- holds,
          route == candidate.route and account == Map.get(candidate, :account),
          do: Map.get(hold, :estimate_percent)

    remaining = if is_map(reading) and Map.get(reading, :stale) != true, do: UsageFloor.remaining_percent(reading)

    if is_number(remaining) and Enum.all?(estimates, &is_number/1),
      do: remaining - Enum.sum(estimates)
  end

  defp floor(candidate, floor_percent) do
    if UsageFloor.held?(Map.get(candidate, :reading), floor_percent), do: {:hold, :floor}, else: :ok
  end

  defp serves(source, kind) do
    case Map.get(source, :serves) do
      serves when is_list(serves) ->
        if to_string(kind) in Enum.map(serves, &to_string/1), do: :ok, else: {:hold, :not_served}

      _default_coding ->
        if to_string(kind) == "coding", do: :ok, else: {:hold, :not_served}
    end
  end
end
