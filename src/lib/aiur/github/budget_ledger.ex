defmodule Aiur.GitHub.BudgetLedger do
  @moduledoc """
  A read-only projection of the broker's admission ledger
  (`~/.aiur/github-budget/budget.sqlite3`), for the GitHub cache page.

  `Aiur.GitHub.Budget` talks to the broker through its Python subprocess; this
  module reads the same SQLite database directly and never writes. Every figure
  here is a byproduct of requests the daemon and the agents were already
  making, so reading it costs nothing and — critically — *creates* no admission.
  That last property is what the page's zero-fetch proof extends to: opening
  and refreshing the cache page must leave the admission count untouched, and
  this module is how the page counts admissions without spending one.

  ## What an admission is

  The broker records one `admissions` row per request it admitted, keyed by
  credential and consumer, tagged with an `endpoint_family` and a `billable`
  flag. `billable = 0` is a reconciled `304`: the request reached GitHub and
  GitHub answered from its own cache, so it cost nothing against the primary
  budget. `billable = 1` is spend that counts.

  An admission is a **request**, never a GraphQL *point*. The quota ranking
  (`Aiur.GitHub.QuotaUsage`) counts points; the ledger counts requests. The two
  disagree by construction, and the page says so rather than presenting either
  as the whole story.

  ## Families are the broker's, and carry its caveat

  `endpoint_family` comes from `priv/github_budget.py`, which buckets anything
  that is not literally `/graphql` as core and — for the agent `gh` wrapper —
  names families like `pulls`, `issues`, `search` and `actions`. Those commands
  are GraphQL on the wire, so until #2297 the family column mis-buckets a large
  share of the agent's spend. The page labels that caveat next to the family
  table rather than pretending the families are budgets.

  ## Failing open

  A missing database, an unreadable file, a busy lock: all read as
  `available?: false`, so the page says the ledger is not readable rather than
  presenting an empty ledger as a measured zero. The broker is optional on a
  host, and a page that crashed because it could not read a file it never wrote
  would be the same failure this page exists to avoid.
  """

  alias Aiur.GitHub.Budget
  alias Exqlite.Basic

  @hour_ms 3_600_000
  @busy_timeout_ms 5_000

  @type snapshot :: %{
          available?: boolean(),
          captured_at_ms: non_neg_integer() | nil,
          admission_count: non_neg_integer() | nil,
          billable: non_neg_integer() | nil,
          free: non_neg_integer() | nil,
          by_family: %{optional(String.t()) => %{billable: non_neg_integer(), free: non_neg_integer()}},
          by_consumer: %{optional(String.t()) => %{billable: non_neg_integer(), free: non_neg_integer()}},
          rows: [%{consumer: String.t(), family: String.t(), billable: non_neg_integer(), free: non_neg_integer()}]
        }

  @doc """
  The admission ledger over the rolling hour, shaped for the page.

  `admission_count` is the total admitted in the window — the figure the
  zero-fetch proof asserts is unchanged across a page refresh. `billable` and
  `free` split it by whether the admission was reconciled as a free `304`.
  `rows` carries the consumer × family × billable split so the page can show
  both the family totals and who is spending where, and `by_family` /
  `by_consumer` are the same data pre-aggregated for the panels that only want
  one axis.

  Options:

    * `:database_path` — where the ledger lives. Defaults to
      `Budget.database_path/0`, overridable so a test can point the page at a
      seeded temp database.
    * `:now_ms` — the clock, so tests can pin the window edge.
  """
  @spec snapshot(keyword()) :: snapshot()
  def snapshot(opts \\ []) do
    path = Keyword.get(opts, :database_path, configured_database_path())
    now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))

    with path when is_binary(path) and path != "" <- path,
         true <- File.regular?(path) do
      read(path, now)
    else
      _unreadable -> unavailable()
    end
  rescue
    _unavailable -> unavailable()
  catch
    :exit, _reason -> unavailable()
  end

  @doc "The rolling-hour window the ledger is read over, in milliseconds."
  @spec window_ms() :: pos_integer()
  def window_ms, do: @hour_ms

  @doc false
  @spec unavailable() :: snapshot()
  def unavailable, do: %{available?: false, captured_at_ms: nil, admission_count: nil, billable: nil, free: nil, by_family: %{}, by_consumer: %{}, rows: []}

  defp read(path, now) do
    cutoff = now - @hour_ms

    case Basic.open(path) do
      {:ok, conn} ->
        try do
          _ = Basic.exec(conn, "PRAGMA busy_timeout = #{@busy_timeout_ms}")
          _ = Basic.exec(conn, "PRAGMA query_only = ON")

          %{
            available?: true,
            captured_at_ms: now,
            admission_count: scalar(conn, "SELECT COUNT(*) FROM admissions WHERE admitted_at_ms > ?", [cutoff]),
            billable: billed(conn, cutoff, 1),
            free: billed(conn, cutoff, 0),
            by_family: family_totals(conn, cutoff),
            by_consumer: consumer_totals(conn, cutoff),
            rows: rows(conn, cutoff)
          }
        after
          Basic.close(conn)
        end

      _unreadable ->
        unavailable()
    end
  end

  defp scalar(conn, sql, args) do
    case Basic.rows(Basic.exec(conn, sql, args)) do
      {:ok, [[value]], _columns} -> value
      _unreadable -> nil
    end
  end

  defp billed(conn, cutoff, billable) do
    scalar(conn, "SELECT COUNT(*) FROM admissions WHERE admitted_at_ms > ? AND billable = ?", [cutoff, billable])
  end

  # `consumer_label` is the human-readable actor name the broker records on the
  # policy row (`daemon:<node>` or `workspace:<path>`); the raw `consumer_key` is
  # a fingerprint, so it is the fallback only when no policy row survived. The
  # join is on the pair the broker itself keys policies by.
  defp rows(conn, cutoff) do
    sql = """
    SELECT COALESCE(p.consumer_label, a.consumer_key, '(unlabelled)') AS consumer,
           a.endpoint_family AS family,
           a.billable AS billable,
           COUNT(*) AS count
    FROM admissions a
    LEFT JOIN policies p ON p.token_key = a.token_key AND p.consumer_key = a.consumer_key
    WHERE a.admitted_at_ms > ?
    GROUP BY consumer, a.endpoint_family, a.billable
    """

    case Basic.rows(Basic.exec(conn, sql, [cutoff])) do
      {:ok, data, _columns} ->
        data
        |> Enum.reduce(%{}, &tally_row/2)
        |> Map.values()
        |> Enum.sort_by(&{&1.consumer, &1.family})

      _unreadable ->
        []
    end
  end

  defp family_totals(conn, cutoff) do
    sql = """
    SELECT a.endpoint_family AS family, a.billable AS billable, COUNT(*) AS count
    FROM admissions a
    WHERE a.admitted_at_ms > ?
    GROUP BY a.endpoint_family, a.billable
    """

    case Basic.rows(Basic.exec(conn, sql, [cutoff])) do
      {:ok, data, _columns} -> Enum.reduce(data, %{}, &tally_bucket/2)
      _unreadable -> %{}
    end
  end

  defp consumer_totals(conn, cutoff) do
    sql = """
    SELECT COALESCE(p.consumer_label, a.consumer_key, '(unlabelled)') AS consumer,
           a.billable AS billable,
           COUNT(*) AS count
    FROM admissions a
    LEFT JOIN policies p ON p.token_key = a.token_key AND p.consumer_key = a.consumer_key
    WHERE a.admitted_at_ms > ?
    GROUP BY consumer, a.billable
    """

    case Basic.rows(Basic.exec(conn, sql, [cutoff])) do
      {:ok, data, _columns} -> Enum.reduce(data, %{}, &tally_bucket/2)
      _unreadable -> %{}
    end
  end

  # One row of a consumer × family × billable count, folded into a map keyed by
  # `{consumer, family}`. The billable bucket chooses which side of the split
  # receives the count.
  defp tally_row([consumer, family, billable, count], acc) do
    key = {consumer, family}
    current = Map.get(acc, key, %{consumer: consumer, family: family, billable: 0, free: 0})

    case billable do
      1 -> Map.put(acc, key, %{current | billable: count})
      _free -> Map.put(acc, key, %{current | free: count})
    end
  end

  # One row of a family-or-consumer × billable count, folded into a map keyed by
  # the label, used by both one-axis totals.
  defp tally_bucket([label, billable, count], acc) do
    key = to_string(label)
    current = Map.get(acc, key, %{billable: 0, free: 0})

    case billable do
      1 -> Map.put(acc, key, %{current | billable: count})
      _free -> Map.put(acc, key, %{current | free: count})
    end
  end

  defp configured_database_path do
    case Application.get_env(:aiur, :github_budget_ledger_path) do
      path when is_binary(path) and path != "" -> path
      _unset -> Budget.database_path()
    end
  end
end
