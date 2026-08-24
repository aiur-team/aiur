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
  is deliberate" rather than as a cache that is failing.
  """

  @table :aiur_github_read_cache_metrics

  # A refusal keyed on a path template is only bounded if the key set is.
  # `Policy.classify/1` returns the route shape of a declined REST read, and the
  # shapes that survive collapse to call families (`rest:GET /repos/:owner/:repo/
  # issues/:n/comments`); a hostile or novel URL must not be able to grow the
  # metric map without bound, so anything beyond the cap folds into `:overflow`.
  @max_refused_shapes 200
  @overflow :overflow

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
  def hit(class, caller), do: bump([{:class, class, :hit}, {:caller, caller, :hit}])

  @doc "Records a cacheable read the cache could not answer."
  @spec miss(atom(), String.t() | nil) :: :ok
  def miss(class, caller), do: bump([{:class, class, :miss}, {:caller, caller, :miss}])

  @doc "Records a response written into the cache."
  @spec deposit(atom(), String.t() | nil) :: :ok
  def deposit(class, caller), do: bump([{:class, class, :deposit}, {:caller, caller, :deposit}])

  @doc """
  Records a cacheable response that was not written into the cache, and why.

  This is the gap between a miss and a deposit, and it is the figure that makes
  a TTL change evaluable: if misses and deposits diverge, the difference is here
  and it is attributable. Two reasons exist, and they ask different questions:

    * `:unsuccessful` — the response failed (`success?/1` refused it), which
      for batched GraphQL means any `errors` key. Common on graph queries, and
      not a cache problem.
    * `:no_room` — the response was good but the entry ceiling was reached.
      `room?/0` refuses new deposits at the ceiling rather than evicting, so
      this is the backstop answering "the cache could not hold it".
  """
  @spec not_deposited(atom(), atom(), String.t() | nil) :: :ok
  def not_deposited(reason, class, caller) when reason in [:unsuccessful, :no_room] do
    bump([{:not_deposited, reason}, {:class, class, :not_deposited}, {:caller, caller, :not_deposited}])
  end

  @doc """
  Records a read the policy declined to cache, with the reason.

  This is not a miss. A miss is a cache that could have helped and did not; a
  refusal is spend the policy has decided is correct. Folding them together
  would make an unsafe kind look like a tuning problem.
  """
  @spec refused(atom(), String.t() | nil) :: :ok
  def refused(reason, caller), do: bump([{:refused, reason}, {:caller, caller, :refused}])

  @doc """
  Records a REST refusal keyed on the request's path template, not the URL.

  `Policy.classify/1` returns `{:no_cache, {:unclassified, shape}}` for a REST
  read it declines, where `shape` is `GraphQLCost.route_shape/1` — the call
  family (`rest:GET /repos/:owner/:repo/issues/:n/comments`), not the 5,000
  distinct reads that pass through it. The key set is capped at
  `#{@max_refused_shapes}` so a pathological URL cannot grow the metric map
  without bound; a shape beyond the cap folds into `:overflow`.

  The by-reason `refused/2` map keeps the non-shape reasons. Folding every
  unrecognised REST call into one `:unclassified` total made the 5,000
  reads/hr of unclassified REST read as a single number no call site could be
  recovered from; this is what makes `aiur github-cost` report refusals by
  shape (#2357).
  """
  @spec refused_shape(String.t(), String.t() | nil) :: :ok
  def refused_shape(shape, caller) do
    bucket =
      if member?({:refused_shapes, shape}) or refused_shape_count() < @max_refused_shapes do
        shape
      else
        @overflow
      end

    bump([{:refused_shapes, bucket}, {:caller, caller, :refused}])
  end

  defp member?(key) do
    :ets.member(@table, key)
  rescue
    ArgumentError -> false
  end

  defp refused_shape_count do
    # The stored object is `{{:refused_shapes, shape}, count}`, so a match spec
    # would need a nested-tuple head (which the spec compiler rejects here);
    # a fold over the table is unambiguous and refusals are low-frequency.
    :ets.foldl(
      fn
        {{:refused_shapes, _shape}, _count}, acc -> acc + 1
        _other, acc -> acc
      end,
      0,
      @table
    )
  rescue
    ArgumentError -> 0
  end

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
        %{
          available?: false,
          classes: %{},
          callers: %{},
          refused: %{},
          refused_shapes: %{},
          not_deposited: %{},
          invalidations: %{},
          totals: empty_totals()
        }

      _live ->
        entries = :ets.tab2list(@table)

        %{
          available?: true,
          classes: group(entries, :class),
          callers: group(entries, :caller),
          refused: refusals(entries),
          refused_shapes: refused_shapes(entries),
          not_deposited: reasons(entries, :not_deposited),
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

  defp bump(keys) do
    Enum.each(keys, &increment(&1, 1))
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

  defp refusals(entries), do: reasons(entries, :refused)

  # The reason split of a class of skip. `not_deposited` counts the reasons a
  # good-or-bad response was not written (`:unsuccessful`, `:no_room`);
  # `refused` counts the reasons the policy declined to cache a read at all.
  # Both are global — a skip has a class for `not_deposited`, but the *reason*
  # is the question an operator asks.
  defp reasons(entries, scope) do
    entries
    |> Enum.filter(&match?({{^scope, _reason}, _count}, &1))
    |> Map.new(fn {{^scope, reason}, count} -> {reason, count} end)
  end

  defp refused_shapes(entries) do
    entries
    |> Enum.filter(&match?({{:refused_shapes, _shape}, _count}, &1))
    |> Map.new(fn {{:refused_shapes, shape}, count} -> {shape, count} end)
  end

  # Hits, misses, deposits and not-deposits total across classes; refusals total
  # across reasons, because a refusal has no class — it is a read the policy
  # declined to classify as cacheable. Summing them from the class rows would
  # leave `refused` permanently at zero, which reads as "nothing was refused"
  # rather than "refusals are not counted here". Shape-keyed REST refusals count
  # toward the same total as the by-reason ones; `not_deposited` totals from the
  # class rows, because it is counted per class like the misses it follows.
  defp totals(entries) do
    counted =
      entries
      |> Enum.filter(&match?({{:class, _name, _event}, _count}, &1))
      |> Enum.reduce(empty_totals(), fn {{_scope, _name, event}, count}, acc ->
        Map.update(acc, event, count, &(&1 + count))
      end)

    refused_total =
      Enum.sum(Map.values(refusals(entries))) + Enum.sum(Map.values(refused_shapes(entries)))

    %{counted | refused: refused_total}
  end

  defp value(entries, key) do
    case List.keyfind(entries, key, 0) do
      {^key, count} -> count
      nil -> 0
    end
  end

  defp empty_totals, do: %{hit: 0, miss: 0, deposit: 0, not_deposited: 0, refused: 0}
end
