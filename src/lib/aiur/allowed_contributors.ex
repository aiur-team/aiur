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
  `observe/2` / `observe_async/2` with an `Aiur.AllowedContributors.Candidate`.
  `Aiur.AllowedContributors.Intake` decides; this process holds the state the
  decision needs, writes the audit record, persists the seen set, publishes the
  wake, and refreshes the allow-list (`Source`) on a timer, alerting when its
  commit changes. See `docs/allowed-contributors.md`.
  """

  use GenServer

  alias Aiur.AllowedContributors.{Audit, Intake, Ledger, Refresh}
  alias Aiur.Events.Publisher
  alias Aiur.Executor.StatePaths
  alias Aiur.GitHub.{Config, Transport}

  @refresh_ms 600_000
  @rate_limit 5
  @on_demand_refresh_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Decides one candidate synchronously; returns the outcome."
  @spec observe(map(), GenServer.server()) :: Intake.outcome() | :inert
  def observe(candidate, server \\ __MODULE__), do: GenServer.call(server, {:observe, candidate}, 30_000)

  @doc "Fire-and-forget form for the poll path, which must never wait on intake."
  @spec observe_async(map(), GenServer.server()) :: :ok
  def observe_async(candidate, server \\ __MODULE__), do: GenServer.cast(server, {:observe, candidate})

  @doc "Refetches the allow-list now. Test and operator support."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh, 30_000)

  @impl true
  def init(opts) do
    case repo(opts) do
      {:ok, {owner, repo}} -> {:ok, initial_state(opts, owner, repo), {:continue, :refresh}}
      :error -> {:ok, %{inert: true}}
    end
  end

  @impl true
  def handle_continue(:refresh, state), do: {:noreply, state |> Refresh.run() |> schedule()}

  @impl true
  def handle_call(_request, _from, %{inert: true} = state), do: {:reply, :inert, state}
  def handle_call({:observe, candidate}, _from, state), do: handle_observe(candidate, state)
  def handle_call(:refresh, _from, state), do: {:reply, :ok, Refresh.run(state)}

  @impl true
  def handle_cast({:observe, _candidate}, %{inert: true} = state), do: {:noreply, state}

  def handle_cast({:observe, candidate}, state) do
    {:reply, _outcome, state} = handle_observe(candidate, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state), do: {:noreply, state |> Refresh.run() |> schedule()}
  def handle_info(_message, state), do: {:noreply, state}

  defp handle_observe(candidate, state) do
    {outcome, state} = state |> maybe_refresh_on_demand() |> Intake.decide(candidate)
    {:reply, outcome, record(outcome, candidate, state)}
  end

  # With no allow-list held (the boot read failed), a sighting retries the read
  # — but at most once a minute. Any stranger can open issues, so an unthrottled
  # retry would let them turn each new issue into three GitHub reads.
  defp maybe_refresh_on_demand(%{snapshot: nil} = state) do
    now = state.mono_fun.()

    if is_nil(state.last_on_demand_refresh) or now - state.last_on_demand_refresh >= @on_demand_refresh_ms,
      do: Refresh.run(%{state | last_on_demand_refresh: now}),
      else: state
  end

  defp maybe_refresh_on_demand(state), do: state

  defp record(:duplicate, _candidate, state), do: state

  defp record({:deferred, reason}, candidate, state) do
    audit(state, :deferred, candidate, reason)
    state
  end

  defp record({:reject, reason}, candidate, state) do
    audit(state, :reject, candidate, reason)
    mark_seen(state, candidate)
  end

  defp record({:accept, via}, candidate, state) do
    publish(state, candidate, via)
    audit(state, :accept, candidate, via)
    mark_seen(state, candidate)
  end

  # A malformed candidate has no number to remember; it is audited, not stored.
  defp mark_seen(state, %{number: number}) when is_integer(number) and number > 0 do
    ledger = Ledger.mark_seen(state.ledger, number, System.os_time(:second))
    :ok = Ledger.save(ledger, state.ledger_path)
    %{state | ledger: ledger}
  end

  defp mark_seen(state, _candidate), do: state

  defp audit(state, decision, candidate, reason),
    do: Audit.record(state.audit_path, decision, candidate, reason, snapshot_sha(state.snapshot), now_iso())

  defp publish(state, candidate, via) do
    payload = %{
      action: "opened",
      author_id: candidate.author_id,
      via: via,
      allowlist_sha: snapshot_sha(state.snapshot)
    }

    state.publish_fun.("ticket.#{candidate.number}.issue.opened.allowed_contributor", payload,
      bypass_contamination: true,
      dedup_key: {"#{state.owner}/#{state.repo}", "allowed_contributor", Integer.to_string(candidate.number)}
    )
  end

  defp schedule(%{refresh_ms: :infinity} = state), do: state

  defp schedule(state) do
    Process.send_after(self(), :refresh, state.refresh_ms)
    state
  end

  defp snapshot_sha(%{sha: sha}), do: sha
  defp snapshot_sha(_snapshot), do: nil

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp repo(opts) do
    case Keyword.get(opts, :repo) do
      {owner, repo} when is_binary(owner) and is_binary(repo) -> {:ok, {owner, repo}}
      nil -> default_repo()
    end
  end

  defp default_repo do
    if Aiur.Config.tracker_kind() == "github", do: Transport.parse_repo() |> ok_or_error(), else: :error
  rescue
    _error -> :error
  end

  defp ok_or_error({:ok, value}), do: {:ok, value}
  defp ok_or_error(_other), do: :error

  defp initial_state(opts, owner, repo) do
    dir = Keyword.get_lazy(opts, :state_dir, &StatePaths.dir/0)
    ledger_path = Path.join(dir, "#{repo}.allowed-contributors.json")

    %{
      owner: owner,
      repo: repo,
      ledger_path: ledger_path,
      audit_path: Path.join(dir, "#{repo}.allowed-contributors.audit.ndjson"),
      ledger: Ledger.load(ledger_path),
      snapshot: nil,
      last_on_demand_refresh: nil,
      membership: %{},
      rate: %{},
      rate_limit: Keyword.get(opts, :rate_limit, @rate_limit),
      refresh_ms: Keyword.get(opts, :refresh_ms, @refresh_ms),
      token_fun: Keyword.get(opts, :token_fun, &Config.token/0),
      request_fun: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
      publish_fun: Keyword.get(opts, :publish_fun, &Publisher.publish/3),
      alert_fun: Keyword.get(opts, :alert_fun, &Aiur.Alerts.emit_custom/3),
      mono_fun: Keyword.get(opts, :mono_fun, fn -> System.monotonic_time(:millisecond) end),
      aiur_logins_fun: Keyword.get(opts, :aiur_logins_fun, &aiur_logins/0)
    }
  end

  defp aiur_logins do
    [Config.bot_account(), Config.daemon_account()]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  rescue
    _error -> []
  end
end
