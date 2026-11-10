# Cohesion: one sample row needs the meters, the policy and the ledger together; splitting would scatter the row shape.
defmodule Aiur.Capacity.SampleLog do
  @moduledoc """
  Appends one capacity sample per probe interval to `<run-log-root>/log/capacity.ndjson`.

  Each line holds one row per account: its reading, projected remaining, reserve,
  open holds, freshness, age and running workers, plus one entry per source
  period that has a USD limit. `aiur capacity report` reads these lines. A figure
  Aiur does not know is written as `null`, never as a number.
  """

  alias Aiur.Accounts.UsageReadings
  alias Aiur.Capacity.{Ledger, LedgerStore}
  alias Aiur.Config.CapacityPolicy
  alias Aiur.LogFile
  alias Aiur.ProviderMeterProjection

  @filename "capacity.ndjson"
  @schema 1

  @doc "The capacity sample log beside the daemon log and telemetry stream: `<run-log-root>/log/capacity.ndjson`."
  @spec path() :: Path.t()
  def path do
    log_file =
      case Application.get_env(:aiur, :log_file) do
        path when is_binary(path) and path != "" -> path
        _other -> LogFile.default_log_file()
      end

    Path.join(Path.dirname(log_file), @filename)
  end

  @doc "Gathers live readings and appends one sample. Never raises."
  @spec record(keyword()) :: :ok
  def record(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    inputs = %{
      accounts: UsageReadings.snapshot(),
      providers: provider_views(),
      running: running_by_account(),
      capacity_policy: capacity_policy(),
      ledger: LedgerStore.ledger()
    }

    append(Keyword.get_lazy(opts, :path, &path/0), sample(inputs, now))
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Builds one sample from per-account meter entries (`UsageReadings.snapshot/0`),
  provider projection views, running workers per `{backend, account}`, the
  effective capacity policy (`:capacity_policy`) and the reservation ledger
  (`:ledger`). Without a policy the reserve is unknown; without a ledger the
  open holds and the projection are.
  """
  @spec sample(map(), DateTime.t()) :: map()
  def sample(inputs, now) do
    policy = Map.get(inputs, :capacity_policy)
    ledger = Map.get(inputs, :ledger)
    running = Map.get(inputs, :running, %{})
    metered = for {{backend, account}, entry} <- Map.get(inputs, :accounts, %{}), do: account_row(backend, account, entry, now)
    metered_backends = MapSet.new(metered, & &1.backend)

    providers =
      for {provider, view} <- Map.get(inputs, :providers, %{}),
          backend = to_string(provider),
          not MapSet.member?(metered_backends, backend),
          do: provider_row(backend, view)

    rows = Enum.map(metered ++ providers, &finish_row(&1, running, policy, ledger))

    %{
      schema: @schema,
      at: DateTime.to_iso8601(now),
      accounts: Enum.sort_by(rows, &{&1.backend, &1.account || ""}),
      sources: limited_sources(policy, now)
    }
  end

  @doc "Appends one sample as a JSON line, creating the directory when missing."
  @spec append(Path.t(), map()) :: :ok | {:error, term()}
  def append(path, sample) do
    with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, [Jason.encode!(sample), ?\n], [:append])
  end

  defp account_row(backend, account, entry, now) do
    observed_at = UsageReadings.observed_at(entry)
    reading = Map.get(entry, :reading)

    %{
      backend: backend,
      account: account,
      remaining_percent: remaining(reading),
      freshness: UsageReadings.freshness(entry, now),
      observed_at: iso(observed_at),
      age_ms: age_ms(observed_at, now)
    }
  end

  # The binding window is the most used of the two windows headroom dispatch scores.
  defp remaining(%{windows: windows}) when is_list(windows) do
    case for(%{window: window, used_percent: used} when window in ["five_hour", "seven_day"] and is_number(used) <- windows, do: used) do
      [] -> nil
      used -> max(round(100 - Enum.max(used)), 0)
    end
  end

  defp remaining(_reading), do: nil

  defp provider_row(backend, view) do
    remaining =
      view
      |> Map.get(:windows, %{})
      |> Map.values()
      |> Enum.map(&Map.get(&1, :remaining_percent))
      |> Enum.filter(&is_number/1)
      |> Enum.min(fn -> nil end)

    freshness = Map.get(view, :freshness, :unknown)
    age = Map.get(view, :age_seconds)

    %{
      backend: backend,
      account: nil,
      remaining_percent: if(freshness == :unknown, do: nil, else: remaining),
      freshness: freshness,
      observed_at: iso(Map.get(view, :observed_at)),
      age_ms: if(is_integer(age), do: age * 1000)
    }
  end

  defp finish_row(row, running, policy, ledger) do
    account = row.account || "default"
    reserve = reserve_percent(policy, row.backend, account)

    Map.merge(row, %{
      projected_percent: projected(ledger, row, account, is_number(reserve) and reserve > 0),
      reserve_percent: reserve,
      open_holds: open_holds(ledger, row.backend, account),
      running: Map.get(running, {row.backend, account}, 0)
    })
  end

  # Mirrors `Aiur.Capacity.Policy`'s reserve rule: 0 when the account has none.
  defp reserve_percent(%{} = policy, backend, account) do
    reserve = get_in(policy, [:sources, backend, :reserve]) || %{}
    accounts = Map.get(reserve, :accounts)
    if is_list(accounts) and account not in accounts, do: 0, else: Map.get(reserve, :percent) || 0
  end

  defp reserve_percent(_no_policy, _backend, _account), do: nil

  defp open_holds(%Ledger{holds: holds}, backend, account),
    do: Enum.count(Map.values(holds), &(&1.backend == backend and &1.account == account and Map.get(&1, :folded_at) == nil))

  defp open_holds(_no_ledger, _backend, _account), do: nil

  # The reading minus the holds created after it; an unknown hold estimate on a reserved account is unknown.
  defp projected(%Ledger{} = ledger, %{remaining_percent: remaining, observed_at: at} = row, account, fail_closed?)
       when is_number(remaining) and is_binary(at) do
    {:ok, observed_at, _offset} = DateTime.from_iso8601(at)

    case Ledger.projected_remaining(ledger, {row.backend, account}, %{remaining: remaining, observed_at: observed_at}, fail_closed?) do
      :unknown -> nil
      value -> value
    end
  end

  defp projected(_ledger, _row, _account, _fail_closed?), do: nil

  # ponytail: no dispatch path records per-source spend yet, so `spend_usd` is null (unknown) for every limited period.
  defp limited_sources(%{} = policy, now) do
    per_source = for {backend, source} <- Map.get(policy, :sources) || %{}, do: {backend, Map.get(source, :limits)}

    for {backend, limits} <- per_source ++ [{"global", Map.get(policy, :limits)}],
        is_map(limits),
        {period, limit} <- Enum.sort(limits),
        is_number(limit),
        do: %{backend: backend, period: period, period_start: period_start(period, DateTime.to_date(now)), limit_usd: limit, spend_usd: nil}
  end

  defp limited_sources(_no_policy, _now), do: []

  defp period_start(:daily_usd, date), do: Date.to_iso8601(date)
  defp period_start(:weekly_usd, date), do: date |> Date.beginning_of_week() |> Date.to_iso8601()
  defp period_start(:monthly_usd, date), do: date |> Date.beginning_of_month() |> Date.to_iso8601()

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_at), do: nil

  defp age_ms(%DateTime{} = at, now), do: max(DateTime.diff(now, at, :millisecond), 0)
  defp age_ms(_at, _now), do: nil

  # An unreadable policy leaves every reserve unknown rather than guessing one.
  defp capacity_policy do
    case CapacityPolicy.effective() do
      {:ok, policy} -> policy
      {:error, _reason} -> nil
    end
  end

  defp provider_views do
    ProviderMeterProjection.snapshot()
  catch
    :exit, _reason -> %{}
  end

  defp running_by_account do
    case Aiur.Orchestrator.snapshot(Aiur.Orchestrator.server(), 5_000) do
      %{running: rows} when is_list(rows) ->
        rows
        |> Enum.filter(&is_binary(&1[:backend]))
        |> Enum.frequencies_by(&{&1[:backend], &1[:account] || "default"})

      _unavailable ->
        %{}
    end
  catch
    :exit, _reason -> %{}
  end
end
