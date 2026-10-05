defmodule Aiur.AllowedContributors do
  @moduledoc """
  Allowed-contributor intake (#2957): a new issue opened by an account or org
  member named in the default branch's `.github/ALLOWED-CONTRIBUTORS` wakes the
  Executor with one `ticket.<n>.issue.opened.allowed_contributor` event.

  **Intake, never dispatch authority.** The wake tells the Executor a trusted
  outside contributor filed work; the issue is dispatched exactly like an
  operator-filed one — when a `tracker.github.allowed_users` actor applies the
  trigger label (`Aiur.GitHub.DispatchAuthorization`). Nothing here applies a
  label or marks an issue authorized, so a compromised allowed account can at
  worst produce a rate-capped number of wakes.

  Producers (the verified `issues.opened` webhook and the open-issue poll) call
  `observe/2`, `observe_async/2` or `offer_open_issues/1` with an
  `Aiur.AllowedContributors.Candidate`. `Intake` decides; this process holds
  the `State`, writes the audit record, persists the seen set, publishes the
  wake, and refreshes the allow-list (`Refresh`) on a timer. See
  `docs/allowed-contributors.md`.

  It sits at the tail of the daemon's `:rest_for_one` tree and never lets a
  GitHub, publish, or disk failure crash it: every such failure is a logged,
  fail-closed decision instead.
  """

  use GenServer

  require Logger

  alias Aiur.AllowedContributors.{Audit, Candidate, Intake, Ledger, RateLimit, Refresh, State, Wake}
  alias Aiur.GitHub.Transport

  @on_demand_refresh_ms 60_000
  @poll_horizon_s 24 * 3600

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Decides one candidate synchronously; returns the outcome."
  @spec observe(map(), GenServer.server()) :: Intake.outcome() | :inert
  def observe(candidate, server \\ __MODULE__), do: GenServer.call(server, {:observe, candidate}, 30_000)

  @doc "Fire-and-forget form for producers that must never wait on intake."
  @spec observe_async(map(), GenServer.server()) :: :ok
  def observe_async(candidate, server \\ __MODULE__), do: GenServer.cast(server, {:observe, candidate})

  @doc """
  Offers the open-issue poll's issues to intake. Only issues created in the
  last 24 hours are offered, so a first boot does not walk the backlog; the
  durable seen set makes every re-sighting a no-op.
  """
  @spec offer_open_issues([Aiur.Issue.t()], GenServer.server()) :: :ok
  def offer_open_issues(issues, server \\ __MODULE__) do
    now = DateTime.utc_now()

    issues
    |> Enum.filter(&(match?(%DateTime{}, &1.created_at) and DateTime.diff(now, &1.created_at) < @poll_horizon_s))
    |> Enum.each(&observe_async(Candidate.from_issue(&1), server))
  end

  @doc "Refetches the allow-list now. Test and operator support."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh, 30_000)

  @impl true
  def init(opts) do
    case repo(opts) do
      {:ok, {owner, repo}} -> {:ok, State.new(opts, owner, repo), {:continue, :refresh}}
      :error -> {:ok, %{inert: true}}
    end
  end

  @impl true
  def handle_continue(:refresh, state), do: {:noreply, state |> safe_refresh() |> schedule()}

  @impl true
  def handle_call(_request, _from, %{inert: true} = state), do: {:reply, :inert, state}
  def handle_call({:observe, candidate}, _from, state), do: handle_observe(candidate, state)
  def handle_call(:refresh, _from, state), do: {:reply, :ok, safe_refresh(state)}

  @impl true
  def handle_cast({:observe, _candidate}, %{inert: true} = state), do: {:noreply, state}

  def handle_cast({:observe, candidate}, state) do
    {:reply, _outcome, state} = handle_observe(candidate, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state), do: {:noreply, state |> safe_refresh() |> schedule()}
  def handle_info(_message, state), do: {:noreply, state}

  defp handle_observe(candidate, state) do
    {outcome, state} = state |> maybe_refresh_on_demand() |> decide(candidate)
    {outcome, state} = record(outcome, candidate, state)
    {:reply, outcome, state}
  end

  defp decide(state, candidate) do
    Intake.decide(state, candidate)
  rescue
    error -> {{:deferred, {:intake_error, Exception.message(error)}}, state}
  end

  # With no allow-list held (the boot read failed), a sighting retries the read
  # — but at most once a minute. Any stranger can open issues, so an unthrottled
  # retry would let them turn each new issue into four GitHub reads.
  defp maybe_refresh_on_demand(%State{snapshot: nil} = state) do
    now = state.clock_fun.()

    if is_nil(state.last_on_demand_refresh) or now - state.last_on_demand_refresh >= @on_demand_refresh_ms,
      do: safe_refresh(%{state | last_on_demand_refresh: now}),
      else: state
  end

  defp maybe_refresh_on_demand(state), do: state

  defp record(:duplicate, _candidate, state), do: {:duplicate, state}

  defp record({:deferred, reason} = outcome, candidate, state) do
    audit(state, :deferred, candidate, reason)
    {outcome, state}
  end

  defp record({:reject, reason} = outcome, candidate, state) do
    audit(state, :reject, candidate, reason)
    {outcome, mark_seen(state, candidate)}
  end

  # An accept counts only once the wake is actually on the bus. A publish that
  # fails is deferred (not remembered), so the next sighting retries it rather
  # than the audit saying "accepted" for a wake nobody received.
  defp record({:accept, via} = outcome, candidate, state) do
    case Wake.publish(state, candidate, via) do
      :ok ->
        audit(state, :accept, candidate, via)
        {outcome, mark_seen(state, candidate)}

      {:error, reason} ->
        deferred = {:deferred, {:publish_failed, reason}}
        audit(state, :deferred, candidate, elem(deferred, 1))
        rate = RateLimit.refund(state.ledger.rate, candidate.author_id)
        {deferred, %{state | ledger: Ledger.put_rate(state.ledger, rate)}}
    end
  end

  defp mark_seen(state, %{number: number}) when is_integer(number) and number > 0 do
    ledger = Ledger.mark_seen(state.ledger, number, state.clock_fun.())
    _ = Ledger.save(ledger, state.ledger_path)
    %{state | ledger: ledger}
  end

  defp mark_seen(state, _candidate), do: state

  defp audit(state, decision, candidate, reason),
    do: Audit.record(state.audit_path, decision, candidate, reason, Wake.sha(state.snapshot), now_iso())

  defp safe_refresh(state) do
    Refresh.run(state)
  rescue
    error ->
      Logger.error("allowed_contributors refresh_raised error=#{Exception.message(error)}")
      state
  end

  defp schedule(%State{refresh_ms: :infinity} = state), do: state

  defp schedule(state) do
    Process.send_after(self(), :refresh, state.refresh_ms)
    state
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp repo(opts) do
    case Keyword.get(opts, :repo) do
      {owner, repo} when is_binary(owner) and is_binary(repo) -> {:ok, {owner, repo}}
      nil -> default_repo()
    end
  end

  defp default_repo do
    with "github" <- Aiur.Config.tracker_kind(), {:ok, repo} <- Transport.parse_repo() do
      {:ok, repo}
    else
      _other -> :error
    end
  rescue
    _error -> :error
  end
end
