defmodule Aiur.Capacity.SampleLog do
  @moduledoc """
  Appends one capacity sample per probe interval to `<run-log-root>/log/capacity.ndjson`.

  Each line holds one row per account: its reading, projected remaining, reserve,
  open holds, freshness, age and running workers. `aiur capacity report` reads
  these lines. A figure Aiur does not know is written as `null`, never as a number.
  """

  alias Aiur.Accounts.UsageReadings
  alias Aiur.ProviderMeterProjection
  alias Aiur.RunTelemetry

  @filename "capacity.ndjson"
  @schema 1

  @doc "The capacity sample log beside the telemetry stream."
  @spec path() :: Path.t()
  def path, do: Path.join(Path.dirname(RunTelemetry.telemetry_file()), @filename)

  @doc "Gathers live readings and appends one sample. Never raises."
  @spec record(keyword()) :: :ok
  def record(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    inputs = %{
      accounts: UsageReadings.snapshot(),
      providers: provider_views(),
      running: running_by_account(),
      policy: policy_inputs()
    }

    append(Keyword.get_lazy(opts, :path, &path/0), sample(inputs, now))
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Builds one sample from per-account meter entries (`UsageReadings.snapshot/0`),
  provider projection views, running workers per `{backend, account}` and the
  policy's per-account figures.
  """
  @spec sample(map(), DateTime.t()) :: map()
  def sample(inputs, now) do
    policy = Map.get(inputs, :policy, %{})
    running = Map.get(inputs, :running, %{})
    metered = for {{backend, account}, entry} <- Map.get(inputs, :accounts, %{}), do: account_row(backend, account, entry, now)
    metered_backends = MapSet.new(metered, & &1.backend)

    providers =
      for {provider, view} <- Map.get(inputs, :providers, %{}),
          backend = to_string(provider),
          not MapSet.member?(metered_backends, backend),
          do: provider_row(backend, view)

    rows = Enum.map(metered ++ providers, &finish_row(&1, running, Map.get(policy, {&1.backend, &1.account}, %{})))

    %{
      schema: @schema,
      at: DateTime.to_iso8601(now),
      accounts: Enum.sort_by(rows, &{&1.backend, &1.account || ""}),
      sources: Map.get(policy, :sources, [])
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

  defp finish_row(row, running, policy) do
    Map.merge(row, %{
      projected_percent: Map.get(policy, :projected_percent),
      reserve_percent: Map.get(policy, :reserve_percent),
      open_holds: Map.get(policy, :open_holds),
      running: Map.get(running, {row.backend, row.account || "default"}, 0)
    })
  end

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_at), do: nil

  defp age_ms(%DateTime{} = at, now), do: max(DateTime.diff(now, at, :millisecond), 0)
  defp age_ms(_at, _now), do: nil

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

  # ponytail: reserve, projected remaining, open holds and per-source spend come from
  # the capacity policy (#7889) and its ledger (#7890); until they land every one is null.
  defp policy_inputs, do: %{}
end
