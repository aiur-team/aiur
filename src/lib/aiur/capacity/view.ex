defmodule Aiur.Capacity.View do
  @moduledoc """
  The `aiur.capacity` v1 view ("Energy", #7893, plan
  `2026-11-08-7881-provider-capacity-policy.md` §6), served by
  `GET /api/v1/capacity` and `aiur capacity`.

  It evaluates the configured routes with the functions dispatch calls —
  `UsageFloorGate.candidates/2`, `HeadroomDispatch.readings/2`, the ledger's
  open holds and `CapacityGate.evaluate/3` — so the view and dispatch cannot
  disagree. It only reads; it never records a hold or an alert.

  `energy.level` is the largest headroom above its reserve that an allowed,
  non-last-resort account has, from 0 to 1. It is `nil` with state `unknown`
  when no account has a known figure, or when an allowed account's figure is
  unknown and none is known to have headroom.
  """

  alias Aiur.Accounts.{Headroom, UsageFloor}
  alias Aiur.Capacity.{LedgerStore, Policy}
  alias Aiur.CodingAgent.{CapacityGate, HeadroomDispatch, UsageFloorGate}
  import Aiur.ControlCLI.Protocol, only: [exit_marker: 1, guarded: 2]

  # Best first: a source takes the state of its best account.
  @states ~w(available last_resort limited reserved held exhausted unknown)
  @periods [daily: :daily_usd, weekly: :weekly_usd, monthly: :monthly_usd]

  @doc "Build the view. Options are those `CapacityGate.evaluate/3` reads, plus `:routes` and `:now`."
  @spec build(keyword()) :: map()
  def build(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    opts = Keyword.put(opts, :now, now)
    policy = Keyword.get_lazy(opts, :capacity_policy, &CapacityGate.policy/0)
    candidates = UsageFloorGate.candidates(Keyword.get_lazy(opts, :routes, &UsageFloorGate.configured_routes/0), opts)
    readings = HeadroomDispatch.readings(candidates, opts)
    holds = Keyword.get_lazy(opts, :capacity_holds, fn -> LedgerStore.policy_holds(candidates, readings, CapacityGate.store(opts)) end)
    %{entries: entries} = CapacityGate.evaluate(candidates, readings, Keyword.merge(opts, capacity_policy: policy, capacity_holds: holds))

    rows = Enum.map(entries, &row(&1, Map.get(readings, Headroom.key(&1.candidate)), holds, policy, now))
    sources = rows |> Enum.group_by(& &1.backend) |> Enum.map(fn {backend, rows} -> source(backend, rows, policy) end) |> Enum.sort_by(& &1.backend)

    %{
      contract: "aiur.capacity",
      contract_version: 1,
      observed_at: iso(now),
      energy: energy(rows),
      sources: sources,
      limits: limits(Map.get(policy, :limits))
    }
  end

  @doc "`aiur capacity [--json]`, run in the daemon."
  @spec rpc(boolean()) :: :ok
  def rpc(json) do
    guarded("capacity", fn ->
      view = build()
      IO.puts(if json, do: Jason.encode!(view), else: render(view))
      exit_marker(0)
    end)
  end

  @doc "The human-readable view."
  @spec render(map()) :: String.t()
  def render(%{energy: energy, sources: sources}) do
    level = if is_number(energy.level), do: " #{round(energy.level * 100)}%", else: ""
    binding = if energy.binding_source, do: " via #{energy.binding_source}", else: ""
    unknown = if energy.unknown_sources != [], do: "; unknown: " <> Enum.join(energy.unknown_sources, ", "), else: ""
    head = "Energy: #{energy.state}#{level}#{binding} (#{energy.freshness}#{ago(energy.age_ms)})#{unknown}"

    Enum.join([head | Enum.flat_map(sources, &source_lines/1)], "\n")
  end

  defp source_lines(source) do
    detail = if source.detail, do: " (#{source.detail})", else: ""
    why = if source.reason, do: "  #{source.reason}#{detail}", else: ""
    ["#{source.backend}  #{source.state}#{why}" | Enum.map(source.accounts, &account_line/1)]
  end

  defp account_line(account) do
    figures = if account.remaining_percent, do: "#{round(account.remaining_percent)}% left, projected #{round(account.projected_percent || 0)}%", else: "no reading"
    reserve = if account.reserved, do: ", reserve #{account.reserve_percent}%", else: ""
    "  #{account.account}  #{figures}#{reserve}, #{account.open_holds} holds, #{account.freshness}#{ago(account.age_ms)}"
  end

  # Unknown figures carry no age, so they render as just "unknown".
  defp ago(nil), do: ""
  defp ago(ms) when ms < 60_000, do: ", #{div(ms, 1000)}s ago"
  defp ago(ms) when ms < 3_600_000, do: ", #{div(ms, 60_000)}m ago"
  defp ago(ms), do: ", #{div(ms, 3_600_000)}h ago"

  defp row(%{candidate: candidate} = entry, reading, holds, policy, now) do
    account = account_row(candidate, reading, holds, policy, now)

    %{
      backend: candidate.backend,
      state: state(entry, account.freshness),
      reason: entry.reason && to_string(entry.reason),
      detail: entry.detail,
      verdict: entry.verdict,
      entry_reason: entry.reason,
      account: account
    }
  end

  defp account_row(candidate, reading, holds, policy, now) do
    account = candidate.account || "default"
    reserve = Map.get(source_policy(policy, candidate.backend), :reserve) || %{}
    reserve_percent = Map.get(reserve, :percent) || 0
    remaining = UsageFloor.remaining_percent(reading)
    observed_at = if remaining, do: observed_at(reading, now)

    %{
      account: account,
      reserved: reserve_percent > 0 and reserve_covers?(Map.get(reserve, :accounts), account),
      remaining_percent: if(observed_at, do: remaining),
      projected_percent: if(observed_at, do: clamp(Policy.projected(%{route: candidate.backend, account: account, reading: reading}, holds), 0, 100)),
      reserve_percent: reserve_percent,
      resets_at: iso(UsageFloor.resets_at(reading)),
      open_holds: Enum.count(holds, &(&1.route == candidate.backend and &1.account == account)),
      observed_at: iso(observed_at),
      age_ms: age_ms(observed_at, now),
      freshness: freshness(observed_at, reading)
    }
  end

  # `accounts: nil` covers every account, as the policy reads it.
  defp reserve_covers?(accounts, account), do: not is_list(accounts) or account in accounts

  defp age_ms(nil, _now), do: nil
  defp age_ms(observed_at, now), do: max(DateTime.diff(now, observed_at, :millisecond), 0)

  defp freshness(nil, _reading), do: "unknown"
  defp freshness(_observed_at, %{stale: true}), do: "stale"
  defp freshness(_observed_at, _reading), do: "fresh"

  defp state(%{verdict: :allow, reason: nil}, "unknown"), do: "unknown"
  defp state(%{verdict: :allow, reason: nil}, _freshness), do: "available"
  defp state(%{reason: reason}, _freshness) when reason in [:last_resort, :last_resort_used], do: "last_resort"
  defp state(%{reason: :limited}, _freshness), do: "limited"
  defp state(%{reason: :reserve}, _freshness), do: "reserved"
  defp state(%{reason: :reading_unknown}, _freshness), do: "unknown"
  defp state(%{reason: :balance_exhausted}, _freshness), do: "exhausted"
  defp state(_held, _freshness), do: "held"

  defp source(backend, rows, policy) do
    source = source_policy(policy, backend)
    best = Enum.min_by(rows, &Enum.find_index(@states, fn state -> state == &1.state end))

    %{
      backend: backend,
      billing: billing(Map.get(source, :billing)),
      serves: Enum.map(Map.get(source, :serves) || ["coding"], &to_string/1),
      last_resort: Map.get(source, :last_resort) == true,
      state: best.state,
      reason: best.reason,
      detail: best.detail,
      accounts: Enum.map(rows, & &1.account),
      # ponytail: no USD balance reading reaches the policy yet; fill from the provider meter when one does.
      balance: nil,
      limits: limits(Map.get(source, :limits))
    }
  end

  defp energy(rows) do
    known = Enum.filter(rows, &(&1.account.freshness != "unknown"))
    open = Enum.filter(rows, &(&1.verdict == :allow and is_nil(&1.entry_reason)))
    headroom = for row <- open, is_number(row.account.projected_percent), do: {clamp((row.account.projected_percent - row.account.reserve_percent) / 100, 0, 1), row}

    cond do
      headroom != [] ->
        {level, row} = Enum.max_by(headroom, &elem(&1, 0))
        energy("available", level, row.backend, rows, row.account)

      known == [] or Enum.any?(open, &is_nil(&1.account.projected_percent)) ->
        energy("unknown", nil, nil, rows, %{observed_at: nil, age_ms: nil, freshness: "unknown"})

      Enum.any?(rows, &(&1.entry_reason == :last_resort_used)) ->
        energy("last_resort", 0.0, nil, rows, Enum.min_by(known, & &1.account.age_ms).account)

      true ->
        energy("exhausted", 0.0, nil, rows, Enum.min_by(known, & &1.account.age_ms).account)
    end
  end

  defp energy(state, level, binding, rows, figure) do
    unknown = for {backend, rows} <- Enum.group_by(rows, & &1.backend), Enum.all?(rows, &(&1.account.freshness == "unknown")), do: backend

    %{
      state: state,
      level: level,
      binding_source: binding,
      unknown_sources: Enum.sort(unknown),
      observed_at: figure.observed_at,
      age_ms: figure.age_ms,
      freshness: figure.freshness
    }
  end

  # Dispatch passes no spend yet, so every limit's spend is unknown, as the policy sees it.
  defp limits(limits) when is_map(limits) do
    for {period, key} <- @periods, limit = Map.get(limits, key), is_number(limit) do
      %{period: to_string(period), limit_usd: limit, spent_usd: nil, reached: nil, observed_at: nil, age_ms: nil, freshness: "unknown"}
    end
  end

  defp limits(_none), do: []

  defp observed_at(%{observed_at: %DateTime{} = at}, _now), do: at
  defp observed_at(%{age_seconds: age}, now) when is_integer(age), do: DateTime.add(now, -age, :second)
  defp observed_at(_reading, _now), do: nil

  defp billing(billing) when billing in [:subscription, :prepaid, :metered, "subscription", "prepaid", "metered"], do: to_string(billing)
  defp billing(_unknown), do: "unknown"

  defp source_policy(policy, backend), do: Map.get(Map.get(policy, :sources) || %{}, backend) || %{}
  defp clamp(nil, _low, _high), do: nil
  defp clamp(value, low, high), do: value |> max(low) |> min(high)
  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso(_none), do: nil
end
