defmodule Aiur.GitHubCostCLI do
  @moduledoc """
  `aiur github-cost` — where the GitHub API budget actually goes, ranked.

  One command, one question. The daemon exhausted a fresh 5,000-point GraphQL
  budget in about twenty minutes while making 192 REST calls, and the first
  answer to "who spent it" blamed the agents. It was the daemon. That answer was
  only available because the two credentials happened to be split; nothing in
  the tree could have said which *call path* was responsible, because every
  GraphQL query but one was recorded at one assumed point.

  So this prints points per hour by call site, and prints the reconciliation
  beside it. The reconciliation is not decoration: a breakdown that does not
  add up to the credential's own `used` figure is a guess with a table around
  it, and the table is exactly as persuasive either way. Stating the shortfall
  is what makes the ranking usable.

  Nothing here is a percentage of success. A caller either accounts for spend or
  it does not, and an unmeasured remainder is named as unmeasured rather than
  averaged into the rows that were measured.
  """

  alias Aiur.GitHub.Quota
  alias Aiur.GitHub.ReadCache
  alias Aiur.JSONSafe

  @table_min_width 96
  @headers ["CALLER", "BUDGET", "POINTS", "POINTS/HR", "CALLS", "SHARE", "SOURCE"]

  @spec run(keyword()) :: 0 | 1
  def run(opts \\ []) do
    case build(opts) do
      {:ok, envelope} ->
        if Keyword.get(opts, :json, false),
          do: IO.puts(Jason.encode!(envelope)),
          else: print_human(envelope, Keyword.get(opts, :format, :auto))

        0

      {:error, reason} ->
        IO.puts(:stderr, "aiur: github-cost #{reason}")
        1
    end
  end

  @doc """
  The ranking envelope, with no output of its own.

  `snapshot_fun` is the seam: the default reads the live `Aiur.GitHub.Quota`,
  and tests hand in a fixed snapshot so the rendering can be asserted without a
  daemon.
  """
  @spec build(keyword()) :: {:ok, map()} | {:error, String.t()}
  def build(opts \\ []) do
    snapshot_fun = Keyword.get(opts, :snapshot_fun, &Quota.snapshot/0)
    budget = Keyword.get(opts, :budget, "graphql")

    with {:ok, snapshot} <- fetch(snapshot_fun),
         {:ok, budget} <- validate_budget(budget) do
      {:ok, envelope(snapshot, budget, opts)}
    end
  end

  defp fetch(snapshot_fun) do
    case snapshot_fun.() do
      %{} = snapshot -> {:ok, snapshot}
      _unavailable -> {:error, "could not read the GitHub quota meter"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, _reason -> {:error, "the GitHub quota meter is not running"}
  end

  defp validate_budget(budget) when budget in ["graphql", "core", "all"], do: {:ok, budget}
  defp validate_budget(budget), do: {:error, "--budget accepts graphql, core or all (got #{inspect(budget)})"}

  defp envelope(snapshot, budget, opts) do
    callers = callers_for(snapshot, budget)
    windows = snapshot |> Map.get(:windows, %{}) |> for_budget(budget)

    JSONSafe.normalize(%{
      schema_version: 1,
      page: "github-cost",
      request: %{budget: budget},
      snapshot: %{
        captured_at: Keyword.get(opts, :now, DateTime.utc_now()),
        state: Map.get(snapshot, :state, :unknown)
      },
      data: %{
        callers: Enum.map(callers, &present_caller(&1, callers)),
        windows: Map.new(windows, fn {resource, window} -> {resource, present_window(window)} end),
        reconciliation: snapshot |> Map.get(:reconciliation, %{}) |> for_budget(budget),
        cache: cache_snapshot(opts)
      }
    })
  end

  # The ranking says where the budget went. This says how much of it did not have
  # to be spent — and, where the cache refused to help, why. The two belong in
  # one view: a caller at the top of the ranking with a large `refused` count is
  # spending deliberately, and a caller at the top with a low hit rate is a
  # tuning problem. Without this column those two look identical.
  defp cache_snapshot(opts) do
    cache_fun = Keyword.get(opts, :cache_fun, &ReadCache.snapshot/0)

    case cache_fun.() do
      %{} = cache -> cache
      _unavailable -> %{available?: false}
    end
  rescue
    _error -> %{available?: false}
  catch
    :exit, _reason -> %{available?: false}
  end

  # `--budget graphql` must not print the core window or the core reconciliation
  # beside it. The two budgets are billed separately on separate windows, and one
  # view showing both invites reading them as one figure.
  defp for_budget(collection, "all"), do: collection
  defp for_budget(collection, budget) when is_map(collection), do: Map.take(collection, [budget])
  defp for_budget(collection, _budget), do: collection

  # Points first, because the whole point of the unit is that a request-count
  # ranking cannot see the query that drains the budget. Within one budget the
  # order is Quota's; across budgets the rows are grouped so two windows are
  # never summed into one ranking.
  defp callers_for(snapshot, "all") do
    snapshot |> Map.get(:callers, []) |> Enum.sort_by(&{&1.resource, -&1.points, -&1.calls, &1.caller})
  end

  defp callers_for(snapshot, budget) do
    snapshot
    |> Map.get(:callers, [])
    |> Enum.filter(&(&1.resource == budget))
    |> Enum.sort_by(&{-&1.points, -&1.calls, &1.caller})
  end

  # Share is of the *attributed* total for that budget, and is labelled as such
  # wherever it is rendered. Sharing out of the window's real spend would read
  # as coverage, which is a different and much stronger claim.
  defp present_caller(caller, all) do
    total = all |> Enum.filter(&(&1.resource == caller.resource)) |> Enum.reduce(0, &(&1.points + &2))

    Map.put(caller, :share_of_attributed, share(caller.points, total))
  end

  defp share(_points, total) when total <= 0, do: nil
  defp share(points, total), do: Float.round(points / total, 4)

  defp present_window(window) when is_map(window), do: Map.take(window, [:limit, :remaining, :used, :reset_at])
  defp present_window(window), do: window

  defp print_human(envelope, format) do
    data = envelope["data"]
    rows = data["callers"]

    if rows == [] do
      # Never `0`. Nothing observed and nothing spent are different facts, and
      # only one of them is good news.
      IO.puts("No GitHub API calls have been attributed in the current window.")
    else
      print_rows(rows, format)
    end

    print_windows(data["windows"])
    print_reconciliation(data["reconciliation"])
    print_cache(data["cache"])
  end

  # Never a bare `0%`. A cache that has been asked nothing and a cache that
  # answers nothing print differently, because only one of them is a problem —
  # the same rule the caller table follows when nothing has been attributed.
  defp print_cache(%{"available?" => true} = cache) do
    IO.puts("")

    IO.puts(
      "read cache: #{hit_rate_line(cache)} — " <>
        "#{value(cache["entries"])} entries, #{totals_line(cache["totals"])}"
    )

    print_refusals(cache["refused"])
  end

  defp print_cache(_cache), do: IO.puts("\nread cache: not running (no measurement)")

  defp hit_rate_line(%{"hit_rate" => rate}) when is_float(rate), do: "#{percent(rate)} of cacheable reads served"
  defp hit_rate_line(_cache), do: "no cacheable reads observed"

  defp totals_line(%{"hit" => hits, "miss" => misses, "deposit" => deposits}),
    do: "#{hits} hits, #{misses} misses, #{deposits} deposits"

  defp totals_line(_totals), do: "no totals"

  defp print_refusals(refused) when is_map(refused) and map_size(refused) > 0 do
    line = Enum.map_join(refused, ", ", fn {reason, count} -> "#{reason} #{count}" end)
    IO.puts("read cache refusals: #{line}")
  end

  defp print_refusals(_refused), do: :ok

  defp print_rows(rows, format) do
    cells = Enum.map(rows, &row_cells/1)

    case resolve_format(format) do
      :table ->
        widths = column_widths([@headers | cells])
        Enum.each([@headers | cells], &IO.puts(table_line(&1, widths)))

      :records ->
        Enum.each(rows, &print_record/1)
    end
  end

  defp row_cells(row) do
    [
      to_string(row["caller"]),
      to_string(row["resource"]),
      to_string(row["points"]),
      number(row["points_per_hour"]),
      to_string(row["calls"]),
      percent(row["share_of_attributed"]),
      if(row["estimated?"], do: "estimated", else: "reported")
    ]
  end

  defp print_record(row) do
    IO.puts("Caller: #{row["caller"]} (#{row["resource"]})")
    IO.puts("  Points: #{row["points"]} over #{row["calls"]} calls")
    IO.puts("  Rate: #{number(row["points_per_hour"])}/hour")
    IO.puts("  Share of attributed: #{percent(row["share_of_attributed"])}")
    IO.puts("  Cost source: #{if row["estimated?"], do: "estimated", else: "reported"}")
  end

  defp print_windows(windows) when is_map(windows) and map_size(windows) > 0 do
    IO.puts("")

    Enum.each(windows, fn {resource, window} ->
      IO.puts(
        "#{resource}: #{value(window["used"])} used of #{value(window["limit"])}, " <>
          "#{value(window["remaining"])} remaining, resets #{value(window["reset_at"])}"
      )
    end)
  end

  defp print_windows(_windows), do: :ok

  defp print_reconciliation(reconciliation) when is_map(reconciliation) and map_size(reconciliation) > 0 do
    IO.puts("")

    Enum.each(reconciliation, fn {resource, figures} ->
      IO.puts("#{resource} reconciliation: #{reconciliation_line(figures)}")
    end)
  end

  defp print_reconciliation(_reconciliation), do: :ok

  defp reconciliation_line(%{"attributed" => attributed, "spend" => spend} = figures) do
    "#{value(attributed)} attributed vs #{value(spend)} spent " <>
      "(delta #{value(figures["delta"])}, margin #{percent(figures["margin"])}) — #{verdict(figures)}"
  end

  defp reconciliation_line(_figures), do: "not measurable"

  # A shortfall is the expected state and is reported as a measurement gap, not
  # as an alarm — spend on this credential from outside the process is real and
  # invisible here. `DOES NOT reconcile` is reserved for an excess, which cannot
  # happen without double counting, so it stays worth reading.
  defp verdict(%{"direction" => "agrees"}), do: "reconciles"

  defp verdict(%{"direction" => "shortfall", "delta" => delta}) when is_integer(delta),
    do: "#{abs(delta)} points unattributed (spend outside this process)"

  defp verdict(%{"direction" => "shortfall"}), do: "some spend unattributed"
  defp verdict(%{"direction" => "excess"}), do: "DOES NOT reconcile — attributed more than was spent"
  defp verdict(_figures), do: "not measurable"

  defp resolve_format(:table), do: :table
  defp resolve_format(:records), do: :records

  defp resolve_format(:auto) do
    case :io.columns() do
      {:ok, width} when width >= @table_min_width -> :table
      _narrow_or_not_a_terminal -> :records
    end
  end

  defp column_widths([first | _rest] = rows) do
    Enum.reduce(rows, List.duplicate(0, length(first)), fn row, widths ->
      Enum.zip_with(row, widths, fn cell, width -> max(String.length(cell), width) end)
    end)
  end

  defp table_line(row, widths) do
    row
    |> Enum.zip(widths)
    |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
    |> String.trim_trailing()
  end

  defp number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp number(value) when is_integer(value), do: Integer.to_string(value)
  defp number(_value), do: "unknown"

  defp percent(value) when is_float(value), do: :erlang.float_to_binary(value * 100, decimals: 1) <> "%"
  defp percent(_value), do: "unknown"

  defp value(nil), do: "unknown"
  defp value(value), do: to_string(value)
end
