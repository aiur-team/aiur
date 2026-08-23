defmodule Aiur.GitHub.ReadCache.Metrics do
  @moduledoc """
  Hit, miss, deposit and invalidation counters for the daemon read cache.

  This ships with the cache rather than after it, on the evidence of the one
  that did not. `Aiur.GitHub.AgentCache` has served agent reads since #2073 and
  there is still no figure for whether it helps, because nothing counted. A
  cache with no effectiveness metric cannot be tuned, cannot be defended, and
  cannot be removed — every claim about it is an opinion.

  ## Nothing observed is not zero

  `Aiur.GitHub.CacheInspector` refuses to render "0 entries" as though zero were
  a measurement, and the same rule holds here. `snapshot/0` answers
  `available?: false` when the counter table does not exist, which is what a
  CLI run outside the daemon sees. A hit rate over no observations is `nil`, not
  `0.0`: a cache that has been asked nothing and a cache that answers nothing
  are different facts and only one of them is bad news.

  ## Counted by class and by caller

  By class, because that is the unit the TTLs are chosen in. By caller, because
  the actionable question is not "is the cache working" but "which call site is
  still paying, and is it paying because it missed or because the policy refuses
  to cache it". A refusal is counted with its reason, so
  `refused[:unsafe_kind]` standing at the top of the table reads as "this spend
  is deliberate" rather than as a cache that is failing. A REST refusal keys on
  its shape (see `refused/2`), so the report names the call family instead of
  folding every unrecognised read into one `unclassified` total.
  """

  alias Aiur.GitHub.ReadCache.Policy

  @table :aiur_github_read_cache_metrics

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Creates the counter table.

  Public and write-concurrent because counting happens on the caller's process —
  the transport chokepoint is on the Orchestrator's hot path, and a metric that
  costs a `GenServer.call` would make measuring the cache more expensive than
  the cache saves.
  """
  @spec init() :: :ok
  def init do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
        :ok

      _existing ->
        :ok
    end
  end

  @doc "Records a served-from-cache read."
  @spec hit(atom(), String.t() | nil) :: :ok
  def hit(class, caller), do: bump({:class, class, :hit}, {:caller, caller, :hit})

  @doc "Records a cacheable read the cache could not answer."
  @spec miss(atom(), String.t() | nil) :: :ok
  def miss(class, caller), do: bump({:class, class, :miss}, {:caller, caller, :miss})

  @doc "Records a response written into the cache."
  @spec deposit(atom(), String.t() | nil) :: :ok
  def deposit(class, caller), do: bump({:class, class, :deposit}, {:caller, caller, :deposit})

  @doc """
  Records a read the policy declined to cache, with the reason.

  This is not a miss. A miss is a cache that could have helped and did not; a
  refusal is spend the policy has decided is correct. Folding them together
  would make an unsafe kind look like a tuning problem.

  A REST refusal arrives as `{:unclassified, shape}` and is keyed on the
  **shape** — `:issue_list`, `:pull_list`, `:repo_events`, `:comment_stream`,
  `:pull_files` — so `aiur github-cost` resolves the one-time `unclassified`
  total into the named call families instead of one opaque bucket. The key is
  bounded by `Policy.shapes/0`: a shape the classifier cannot name (which would
  mean a future classifier grew a dynamic shape) is folded back to
  `:unclassified`, so a pathological URL can never grow the metric map.
  """
  @spec refused(atom() | {atom(), atom()}, String.t() | nil) :: :ok
  def refused({:unclassified, shape}, caller) do
    key = if shape in Policy.shapes(), do: shape, else: :unclassified
    bump({:refused, key}, {:caller, caller, :refused})
  end

  def refused(reason, caller), do: bump({:refused, reason}, {:caller, caller, :refused})

  @doc "Records identities retired by a write or a delivery."
  @spec invalidation(non_neg_integer()) :: :ok
  def invalidation(count) when is_integer(count) and count > 0 do
    increment({:invalidations, :marks}, count)
    increment({:invalidations, :events}, 1)
  end

  def invalidation(_count), do: :ok

  @doc """
  Everything counted since the daemon started.

  Shaped for a report: `available?` first, so a caller cannot read the figures
  without first reading whether there are any.
  """
  @spec snapshot() :: map()
  def snapshot do
    case :ets.info(@table) do
      :undefined ->
        %{available?: false, classes: %{}, callers: %{}, refused: %{}, invalidations: %{}, totals: empty_totals()}

      _live ->
        entries = :ets.tab2list(@table)

        %{
          available?: true,
          classes: group(entries, :class),
          callers: group(entries, :caller),
          refused: refusals(entries),
          invalidations: %{
            marks: value(entries, {:invalidations, :marks}),
            events: value(entries, {:invalidations, :events})
          },
          totals: totals(entries)
        }
    end
  end

  @doc """
  Hits as a fraction of hits plus misses, or `nil` when nothing was observed.

  Refusals are excluded on purpose. Including them would make the ratio answer
  "what share of GitHub reads did the cache serve", which sounds like the same
  question and is not: it drops whenever the policy correctly refuses more, so
  it would punish exactly the change that makes the cache safe.
  """
  @spec hit_rate(map()) :: float() | nil
  def hit_rate(%{hit: hits, miss: misses}) when hits + misses > 0, do: Float.round(hits / (hits + misses), 4)
  def hit_rate(_counts), do: nil

  @doc false
  @spec reset() :: :ok
  def reset do
    case :ets.info(@table) do
      :undefined ->
        :ok

      _live ->
        # Two statements rather than `delete_all_objects(...) && :ok`. That form
        # reads as "clear it, and answer :ok if that worked", but
        # `:ets.delete_all_objects/1` is specified to return `true` and nothing
        # else — the failure it appears to guard against is a raise, which no
        # `&&` can catch. Dialyzer proved the falsy branch unreachable
        # (`guard_fail`), and it was right: the conditional was decoration on a
        # call whose only failure mode is an exception.
        :ets.delete_all_objects(@table)
        :ok
    end
  end

  defp bump(class_key, caller_key) do
    increment(class_key, 1)
    increment(caller_key, 1)
  end

  defp increment(key, amount) do
    :ets.update_counter(@table, key, amount, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp group(entries, scope) do
    entries
    |> Enum.filter(&match?({{^scope, _name, _event}, _count}, &1))
    |> Enum.group_by(fn {{_scope, name, _event}, _count} -> name end, fn {{_scope, _name, event}, count} ->
      {event, count}
    end)
    |> Map.new(fn {name, events} -> {name, Map.merge(empty_totals(), Map.new(events))} end)
  end

  defp refusals(entries) do
    entries
    |> Enum.filter(&match?({{:refused, _reason}, _count}, &1))
    |> Map.new(fn {{:refused, reason}, count} -> {reason, count} end)
  end

  # Hits, misses and deposits total across classes; refusals total across
  # reasons, because a refusal has no class — it is a read the policy declined
  # to classify as cacheable. Summing them from the class rows would leave
  # `refused` permanently at zero, which reads as "nothing was refused" rather
  # than "refusals are not counted here".
  defp totals(entries) do
    counted =
      entries
      |> Enum.filter(&match?({{:class, _name, _event}, _count}, &1))
      |> Enum.reduce(empty_totals(), fn {{_scope, _name, event}, count}, acc ->
        Map.update(acc, event, count, &(&1 + count))
      end)

    %{counted | refused: entries |> refusals() |> Map.values() |> Enum.sum()}
  end

  defp value(entries, key) do
    case List.keyfind(entries, key, 0) do
      {^key, count} -> count
      nil -> 0
    end
  end

  defp empty_totals, do: %{hit: 0, miss: 0, deposit: 0, refused: 0}
end
