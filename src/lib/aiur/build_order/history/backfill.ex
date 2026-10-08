defmodule Aiur.BuildOrder.History.Backfill do
  @moduledoc "Daemon-owned, resumable one-time repository history walk."
  use GenServer
  alias Aiur.BuildOrder.GitHubGraph.Request
  alias Aiur.BuildOrder.History
  alias Aiur.BuildOrder.History.{BackfillQuery, IssueNode}
  alias Aiur.GitHub.{Config, Errors, LocalHold, Transport}

  # ponytail: fixed pacing and one query version; add tuning only if large repositories need it.
  @query_version 1
  @start_delay_ms 60_000
  @page_interval_ms 10_000
  @history_retry_ms 60_000
  @reserve_fraction 0.2
  @hourly_point_cap 300
  @max_retries 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  @spec status(GenServer.server()) :: {atom(), map()}
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _reason -> {:unavailable, %{reason: :backfill_not_running}}
  end

  @impl true
  def init(opts) do
    state = %{
      status: {:unavailable, %{reason: :initializing}},
      history: [server: Keyword.get(opts, :history, History)],
      request_fun: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
      now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
      schedule_fun: Keyword.get(opts, :schedule_fun, &Process.send_after/3),
      prefix: Keyword.get_lazy(opts, :label_prefix, &safe_prefix/0),
      repo: nil,
      token: nil,
      checkpoint: nil,
      rate_limit: %{},
      spending: [],
      retries: 0,
      due: nil
    }

    {:ok, initialize(state, opts)}
  end

  defp initialize(state, opts) do
    with true <- Keyword.get(opts, :enabled?, true),
         "github" <- safe_call(Keyword.get(opts, :tracker_kind_fun, &Aiur.Config.tracker_kind/0)),
         {:ok, {owner, repo}} <- safe_call(Keyword.get(opts, :repo_fun, &Config.configured_repo/0)),
         {:ok, token} <- safe_call(Keyword.get(opts, :token_fun, &Transport.require_token/0)) do
      schedule(%{state | repo: %{owner: owner, repository: repo}, token: token}, @start_delay_ms, :running, %{pages: 0, issues: 0, points: 0})
    else
      {:error, reason} -> %{state | status: {:unavailable, %{reason: reason}}}
      _other -> %{state | status: {:not_applicable, %{}}}
    end
  end

  defp safe_call(fun) do
    fun.()
  rescue
    _error -> :not_applicable
  end

  defp safe_prefix do
    Config.label_prefix()
  rescue
    _error -> "agent"
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}
  @impl true
  def handle_info(:step, %{status: {status, _detail}} = state) when status in [:complete, :failed, :not_applicable, :unavailable], do: {:noreply, state}

  def handle_info(:step, state) do
    if state.due && DateTime.compare(state.now_fun.(), state.due) == :lt, do: {:noreply, state}, else: {:noreply, check(%{state | due: nil})}
  end

  defp check(state) do
    health = History.health(state.history)

    cond do
      not History.writable?(health) -> schedule(state, @history_retry_ms, :waiting_for_history, %{reason: health.failure})
      is_nil(state.checkpoint) -> load_checkpoint(state, health)
      true -> next_request(state)
    end
  end

  defp load_checkpoint(state, health) do
    case History.checkpoint(:backfill, state.history) do
      {:ok, %{"query_version" => @query_version, "status" => "complete"} = cp} ->
        if health.complete?, do: %{state | checkpoint: cp, status: {:complete, detail(cp)}}, else: finish(%{state | checkpoint: cp})

      {:ok, %{"query_version" => @query_version} = cp} ->
        next_request(%{state | checkpoint: cp})

      {:ok, _old} ->
        next_request(%{state | checkpoint: fresh_checkpoint(state.now_fun.())})

      {:error, failure} ->
        schedule(state, @history_retry_ms, :waiting_for_history, %{reason: failure})
    end
  end

  defp fresh_checkpoint(now) do
    %{
      "query_version" => @query_version,
      "status" => "running",
      "cursor" => nil,
      "pages" => 0,
      "issues" => 0,
      "points" => 0,
      "total" => 0,
      "started_at" => DateTime.to_iso8601(now),
      "completed_at" => nil,
      "root_done" => false,
      "pending_blockers" => []
    }
  end

  defp next_request(state) do
    now = state.now_fun.()
    spending = Enum.filter(state.spending, fn {at, _cost} -> DateTime.diff(now, at, :millisecond) < 3_600_000 end)
    state = %{state | spending: spending}

    cond do
      state.checkpoint["root_done"] == true and state.checkpoint["pending_blockers"] == [] ->
        finish(state)

      Enum.sum(Enum.map(spending, &elem(&1, 1))) >= @hourly_point_cap ->
        {oldest, _cost} = List.last(spending)
        hold(state, DateTime.add(oldest, 3_600, :second), :hourly_point_cap)

      reserve?(state.rate_limit) and future_reset(state.rate_limit, now) != nil ->
        hold(state, future_reset(state.rate_limit, now), :reserve)

      true ->
        fetch(state)
    end
  end

  defp reserve?(%{remaining: remaining, limit: limit}) when is_integer(remaining) and is_integer(limit) and limit > 0, do: remaining < limit * @reserve_fraction
  defp reserve?(_rl), do: false

  defp future_reset(rl, now) do
    at = reset_at(Map.get(rl, :reset_at))
    if at && DateTime.compare(at, now) == :gt, do: at
  end

  defp fetch(state) do
    {query, variables} = document(state)
    request = %{request_fun: state.request_fun, calls: 0, pages: 0, page_budget: 1, call_budget: 1, rate_limit: %{}}

    case Request.page(request, state.token, query, variables) do
      {:ok, body, %{rate_limit: rl}} -> receive_page(record_spend(state, rl), body)
      {:error, reason, %{rate_limit: rl}} -> handle_error(record_spend(state, rl), reason)
    end
  end

  defp document(state) do
    case state.checkpoint["pending_blockers"] do
      [%{"number" => number, "cursor" => cursor} | _rest] ->
        {BackfillQuery.blocked_by_query(), Map.put(BackfillQuery.variables(state.repo.owner, state.repo.repository, cursor), "number", number)}

      _none ->
        {BackfillQuery.query(), BackfillQuery.variables(state.repo.owner, state.repo.repository, state.checkpoint["cursor"])}
    end
  end

  defp record_spend(state, rl) do
    spending =
      case rl do
        %{cost: cost} when is_integer(cost) and cost >= 0 -> [{state.now_fun.(), cost} | state.spending]
        _unknown -> state.spending
      end

    %{state | spending: spending, rate_limit: Map.merge(Map.delete(state.rate_limit, :cost), rl)}
  end

  defp receive_page(state, body) do
    result =
      case state.checkpoint["pending_blockers"] do
        [pending | rest] -> overflow(state, body, pending, rest)
        _none -> root_page(state, body)
      end

    case result do
      {:ok, events, cp} -> persist_page(state, events, cp)
      {:error, reason} -> fail(state, reason)
    end
  end

  defp root_page(state, body) do
    with {:ok, events, info} <- BackfillQuery.events(body, state.repo, state.prefix, state.now_fun.()),
         true <- not info["hasNextPage"] or info["endCursor"] != state.checkpoint["cursor"] do
      cp =
        Map.merge(state.checkpoint, %{
          "cursor" => info["endCursor"],
          "pages" => state.checkpoint["pages"] + 1,
          "issues" => state.checkpoint["issues"] + length(events),
          "total" => info["total"],
          "root_done" => not info["hasNextPage"],
          "pending_blockers" => info["pending_blockers"]
        })

      {:ok, events, cp}
    else
      _error -> {:error, :invalid_backfill_page}
    end
  end

  defp overflow(state, body, pending, rest) do
    with {:ok, refs, info} <- BackfillQuery.blocked_by_events(body),
         true <- not info["hasNextPage"] or info["endCursor"] != pending["cursor"],
         {:ok, old_refs, _info} <- IssueNode.blockers(%{"nodes" => pending["refs"], "pageInfo" => %{"hasNextPage" => false}}),
         {:ok, updated} <- IssueNode.datetime(pending["updated_at"]),
         {:ok, observed} <- IssueNode.datetime(pending["observed_at"]) do
      refs = Enum.uniq(old_refs ++ refs)
      event = %{number: pending["number"], observed_at: observed, source: :backfill, fields: %{updated_at: updated, blocked_by: refs, blocked_by_complete: not info["hasNextPage"]}}
      pending = Map.merge(pending, %{"cursor" => info["endCursor"], "refs" => Enum.map(refs, &graphql_ref/1)})
      queue = if info["hasNextPage"], do: [pending | rest], else: rest
      {:ok, [event], Map.put(state.checkpoint, "pending_blockers", queue)}
    else
      _error -> {:error, :invalid_backfill_page}
    end
  end

  defp graphql_ref(ref), do: %{"number" => ref.number, "repository" => %{"name" => ref.repository, "owner" => %{"login" => ref.owner}}}

  defp persist_page(state, events, cp) do
    cp = Map.put(cp, "points", cp["points"] + Map.get(state.rate_limit, :cost, 0))
    done? = cp["root_done"] and cp["pending_blockers"] == []
    cp = if done?, do: Map.merge(cp, %{"status" => "complete", "completed_at" => DateTime.to_iso8601(state.now_fun.())}), else: cp

    case History.apply(events, state.history ++ [checkpoint: {:backfill, cp}]) do
      {:ok, _result} ->
        state = %{state | checkpoint: cp, retries: 0}
        if done?, do: finish(state), else: pace(state)

      {:error, reason} ->
        fail(state, reason)
    end
  end

  defp pace(state) do
    at = future_reset(state.rate_limit, state.now_fun.())
    if reserve?(state.rate_limit) and at, do: hold(state, at, :reserve), else: schedule(state, @page_interval_ms, :running, detail(state.checkpoint))
  end

  defp finish(state) do
    with :ok <- History.mark_complete(state.history), :ok <- History.flush(state.history) do
      %{state | status: {:complete, detail(state.checkpoint)}, due: nil}
    else
      {:error, reason} -> fail(state, reason)
    end
  end

  defp handle_error(state, {:github, :rate_limited, detail}) do
    at =
      reset_at(Map.get(detail, :reset_at)) || retry_after(detail, state.now_fun.()) || future_reset(state.rate_limit, state.now_fun.()) || DateTime.add(state.now_fun.(), backoff(state), :millisecond)

    hold(state, at, :rate_limited)
  end

  defp handle_error(state, {family, kind, detail} = error) when family in [:aiur, :github] and is_map(detail) do
    case reset_at(Map.get(detail, :reset_at)) do
      %DateTime{} = at when kind in [:locally_held, :local_hold] -> hold(state, at, :local_hold)
      _other -> retry_or_fail(state, error)
    end
  end

  defp handle_error(state, error), do: retry_or_fail(state, error)

  defp retry_or_fail(state, reason) do
    if (reason == :graphql_partial or Errors.retryable_github_error?(reason)) and state.retries < @max_retries,
      do: schedule(%{state | retries: state.retries + 1}, backoff(state), :running, Map.put(detail(state.checkpoint), :retry, state.retries + 1)),
      else: fail(state, reason)
  end

  defp backoff(state), do: LocalHold.backoff_base_ms() * Integer.pow(2, state.retries)
  defp retry_after(%{retry_after: seconds}, now) when is_integer(seconds) and seconds >= 0, do: DateTime.add(now, seconds, :second)
  defp retry_after(_detail, _now), do: nil
  defp reset_at(%DateTime{} = at), do: at

  defp reset_at(value) do
    case IssueNode.datetime(value) do
      {:ok, at} -> at
      _error -> nil
    end
  end

  defp hold(state, at, reason), do: schedule(state, max(DateTime.diff(at, state.now_fun.(), :millisecond), 1), :held, %{until: at, reason: reason})
  defp fail(state, reason), do: %{state | status: {:failed, %{reason: reason, at: state.now_fun.()}}, due: nil}

  defp schedule(state, delay, status, detail) do
    state.schedule_fun.(self(), :step, delay)
    %{state | status: {status, detail}, due: DateTime.add(state.now_fun.(), delay, :millisecond)}
  end

  defp detail(cp), do: %{pages: cp["pages"], issues: cp["issues"], total: cp["total"], points: cp["points"], completed_at: cp["completed_at"], started_at: cp["started_at"]}
end
