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

  `schema_version` is `2` on every envelope, including the single-credential
  default where the payload is byte-identical to version 1. The version states
  what this command's schema *can* contain, not what one payload happens to
  contain. Consumers should branch on whether `data.credentials` is present.
  """

  alias Aiur.GitHub.BudgetLedger
  alias Aiur.GitHub.CredentialUsage
  alias Aiur.GitHub.Quota
  alias Aiur.GitHub.ReadCache
  alias Aiur.JSONSafe

  @table_min_width 96
  @headers ["CALLER", "BUDGET", "POINTS", "POINTS/HR", "CALLS", "SHARE", "SOURCE"]

  @doc """
  The broker's admission ledger retention, in seconds.

  The ledger keeps one rolling hour of admissions — the same window GitHub's
  `/rate_limit` buckets are measured over — so it can only ever be reconciled
  against that span. `aiur github-cost` prints this beside its totals (#2353):
  the ledger is a spend *record*, not a meter, and nothing outside the window
  can be checked against `/rate_limit` after the fact.
  """
  @spec ledger_window_seconds() :: pos_integer()
  def ledger_window_seconds, do: div(BudgetLedger.window_ms(), 1_000)

  @spec ledger_window() :: %{window_seconds: pos_integer(), window_label: String.t()}
  defp ledger_window, do: %{window_seconds: ledger_window_seconds(), window_label: "1 hour"}

  @spec run(keyword()) :: 0 | 1
  def run(opts \\ []) do
    error_fun = Keyword.get(opts, :error_fun, &default_error/1)

    case build(Keyword.delete(opts, :error_fun)) do
      {:ok, envelope} ->
        if Keyword.get(opts, :json, false),
          do: IO.puts(Jason.encode!(envelope)),
          else: print_human(envelope, Keyword.get(opts, :format, :auto))

        0

      {:error, reason} ->
        error_fun.("aiur: github-cost #{reason}")
        1
    end
  end

  defp default_error(message), do: IO.puts(:stderr, message)

  @doc """
  The ranking envelope, with no output of its own.

  `snapshot_fun` is the seam: the default strictly reads the live
  `Aiur.GitHub.Quota`, and tests hand in a fixed snapshot so the rendering can
  be asserted without a daemon. Unlike dashboard projections, this diagnostic
  must fail when its meter cannot be reached.
  """
  @spec build(keyword()) :: {:ok, map()} | {:error, String.t()}
  def build(opts \\ []) do
    snapshot_fun = Keyword.get(opts, :snapshot_fun, &Quota.snapshot!/0)
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
    # Cost reads GitHub's own windows, never the broker's admission counts, so
    # it does not pay for a broker subprocess it would not read.
    rows = CredentialUsage.rows(Keyword.put_new(opts, :usage_fun, fn -> %{actors: []} end))
    pool = opts |> Keyword.put(:rows, rows) |> CredentialUsage.pool() |> for_budget(budget)

    JSONSafe.normalize(%{
      schema_version: 2,
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
        cache: cache_snapshot(opts),
        ledger: ledger_window()
      }
    })
    |> put_credential_view(rows, budget, callers, pool)
  end

  # A pool of one is not a pool. With the single configured credential that is
  # the default, the report is exactly what it was: the existing per-credential
  # reconciliation already says everything a second section would repeat, and
  # printing an empty comparison would read as a measurement where there is
  # none.
  defp put_credential_view(envelope, rows, _budget, _callers, _pool) when length(rows) < 2, do: envelope

  defp put_credential_view(envelope, rows, budget, callers, pool) do
    view =
      JSONSafe.normalize(%{
        credentials: Enum.map(rows, &present_credential(&1, budget)),
        pool_reconciliation: pool_reconciliation(callers, pool)
      })

    update_in(envelope["data"], &Map.merge(&1, view))
  end

  defp present_credential(row, budget) do
    %{
      id: row.id,
      kind: row.kind,
      identity: row.identity,
      writes: row.writes?,
      available: row.available?,
      windows: for_budget(row.windows, budget)
    }
  end

  # The per-caller ranking is point-accurate but credential-blind: it records
  # what a call site cost, not which credential paid. Pooling therefore makes
  # the existing reconciliation caveat sharper rather than softer — the
  # attributed points span the whole pool, while an observed window covers one
  # credential. A pool spend figure is comparable to attribution only when every
  # configured credential has been observed this window; otherwise it is a floor
  # and the delta it produces is not evidence, so it is refused by name.
  defp pool_reconciliation(callers, pool) do
    Map.new(pool, fn {resource, figures} ->
      attributed = callers |> Enum.filter(&(&1.resource == resource)) |> Enum.reduce(0, &(&1.points + &2))

      {resource, pool_figures(attributed, figures)}
    end)
  end

  defp pool_figures(attributed, %{complete?: true, used: used} = figures) when is_integer(used) do
    %{
      attributed: attributed,
      pool_spend: used,
      delta: attributed - used,
      credentials: figures.configured_credentials,
      measurable?: true
    }
  end

  defp pool_figures(attributed, figures) do
    %{
      attributed: attributed,
      pool_spend: figures.used,
      delta: nil,
      credentials: figures.configured_credentials,
      observed_credentials: figures.observed_credentials,
      measurable?: false
    }
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
    print_ledger(data["ledger"])
    # Reading order, not merge order. The ranking says where the budget went,
    # the window says how much is left, the reconciliation says whether the
    # ranking adds up, and the cache says how much never had to be spent — that
    # is the whole question for the single-credential default, and those four
    # always print.
    #
    # The pool sections come last because they are a drill-down that only exists
    # when more than one credential is configured. Within them the order mirrors
    # the single-credential one above: per-credential windows first, then the
    # pool-wide reconciliation that adds them up.
    print_cache(data["cache"])
    print_credentials(data["credentials"])
    print_pool_reconciliation(data["pool_reconciliation"])
  end

  # The ledger window is a scope warning, not a number to reconcile against.
  # The broker's `admissions` are pruned at one rolling hour, so any attempt to
  # reconcile a longer interval against `/rate_limit` is guaranteed to fail;
  # stating the window beside the totals is what keeps the two from being read
  # as covering the same span (#2353).
  defp print_ledger(%{"window_seconds" => seconds} = ledger) when is_integer(seconds) do
    label = Map.get(ledger, "window_label") || "#{seconds}s"
    IO.puts("")
    # Deliberately avoids the word "reconcile": an unobserved meter's report
    # must never mention reconciliation (credential_usage_test's pre-existing
    # guarantee), so the window is stated as the span any comparison is bound
    # to instead (#2353).
    IO.puts("admission ledger window: #{label} — the ledger holds one rolling hour, so match it against at most that span of /rate_limit")
  end

  defp print_ledger(_ledger), do: :ok

  defp print_credentials(credentials) when is_list(credentials) and credentials != [] do
    IO.puts("")

    Enum.each(credentials, fn credential ->
      IO.puts(
        "credential #{credential["id"]} (#{credential["kind"]}, #{credential["identity"] || "unknown-identity"}, #{if credential["writes"], do: "read+write", else: "read-only"}): #{credential_windows(credential["windows"])}"
      )
    end)
  end

  defp print_credentials(_credentials), do: :ok

  defp credential_windows(windows) when is_map(windows) and map_size(windows) > 0 do
    Enum.map_join(windows, "; ", fn
      {resource, window} when is_map(window) ->
        "#{resource} #{value(window["remaining"])} of #{value(window["limit"])} left"

      {resource, _absent} ->
        "#{resource} not observed this window"
    end)
  end

  defp credential_windows(_windows), do: "no window observed"

  defp print_pool_reconciliation(pool) when is_map(pool) and map_size(pool) > 0 do
    IO.puts("")

    Enum.each(pool, fn {resource, figures} ->
      IO.puts("#{resource} pool reconciliation: #{pool_line(figures)}")
    end)
  end

  defp print_pool_reconciliation(_pool), do: :ok

  defp pool_line(%{"measurable?" => true} = figures) do
    "#{value(figures["attributed"])} attributed vs #{value(figures["pool_spend"])} spent across #{value(figures["credentials"])} credentials " <>
      "(delta #{value(figures["delta"])})"
  end

  defp pool_line(figures) do
    "not measurable — #{value(figures["observed_credentials"])} of #{value(figures["credentials"])} credentials observed this window, " <>
      "so pool spend is a floor and no delta is claimed"
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
    print_not_deposited(cache["not_deposited"])
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

  # The accounting remainder: every miss either deposited or did not, and the
  # not-deposited side is split by why. Without it, `misses` minus `deposits`
  # is a silent subtraction an operator cannot tell apart from the cache being
  # short of work.
  defp print_not_deposited(not_deposited) when is_map(not_deposited) and map_size(not_deposited) > 0 do
    line = Enum.map_join(not_deposited, ", ", fn {reason, count} -> "#{reason} #{count}" end)
    IO.puts("read cache not deposited: #{line}")
  end

  defp print_not_deposited(_not_deposited), do: :ok

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
