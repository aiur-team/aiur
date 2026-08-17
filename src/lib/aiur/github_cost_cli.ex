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
    windows = Map.get(snapshot, :windows, %{})

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
        reconciliation: Map.get(snapshot, :reconciliation, %{})
      }
    })
  end

  defp callers_for(snapshot, "all"), do: Map.get(snapshot, :callers, [])

  defp callers_for(snapshot, budget) do
    snapshot |> Map.get(:callers, []) |> Enum.filter(&(&1.resource == budget))
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
  end

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
    verdict =
      case figures["reconciled?"] do
        true -> "reconciles"
        false -> "DOES NOT reconcile"
        _unknown -> "not measurable"
      end

    delta = figures["delta"]
    margin = figures["margin"]

    "#{value(attributed)} attributed vs #{value(spend)} spent " <>
      "(delta #{value(delta)}, margin #{percent(margin)}) — #{verdict}"
  end

  defp reconciliation_line(_figures), do: "not measurable"

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
