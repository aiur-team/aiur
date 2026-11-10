defmodule Aiur.Capacity.LedgerStore do
  @moduledoc """
  The daemon's one `Aiur.Capacity.Ledger` (#7890), shared by every project's
  dispatcher because accounts are machine-wide.

  `Aiur.CodingAgent.CapacityGate` reads `policy_holds/3` to rank candidates.
  Dispatch then calls `claim/2`, which re-checks the selected account's reserve
  against the open holds and records the hold in the same call, so two
  dispatchers cannot both pass one reserve slot.

  Each hold is tied to a live process: the dispatcher that claimed it, then the
  agent worker `attach/3` hands it to. The store monitors that process and
  releases the hold when it exits, so a finished, crashed or cancelled agent
  never keeps one. A dispatch that declines after the claim releases it.
  Handoff adoption rebuilds holds from the adopted workers, so nothing is
  written to disk.

  Only `:window` holds on subscription accounts are recorded: they are what
  the reserve reads. Every call is a no-op when the store is not running.
  """

  use GenServer

  alias Aiur.Accounts.{Headroom, UsageFloor}
  alias Aiur.Capacity.Ledger

  # ponytail: a hold is one agent-hour of burn, folded at the next fresh reading; size by run length if that undershoots.
  @expected_hours 1

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  The open holds in `Aiur.Capacity.Policy`'s `:holds` shape. Folds each
  candidate's reading first, so a hold older than its account's reading no
  longer subtracts. An unknown estimate is `estimate_percent: nil`.
  """
  @spec policy_holds([map()], map(), GenServer.server() | nil) :: [map()]
  def policy_holds(candidates, readings, server \\ __MODULE__), do: call(server, {:policy_holds, candidates, readings}, [])

  @doc """
  Checks the selected account's reserve against its last folded reading minus
  the open holds and, when allowed, records the hold owned by `:owner`
  (default the caller). Returns `:ok` or `{:hold, reason}`.
  """
  @spec claim(map(), keyword()) :: :ok | {:hold, atom()}
  def claim(issue, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    owner = Keyword.get(opts, :owner, self())
    call(Keyword.get(opts, :server, __MODULE__), {:claim, issue, now, Keyword.get(opts, :capacity_policy, %{}), owner}, :ok)
  end

  @doc "Hands a ticket's hold to the agent worker that now runs it."
  @spec attach(term(), pid(), GenServer.server() | nil) :: :ok
  def attach(ticket, pid, server \\ __MODULE__) when is_pid(pid), do: call(server, {:attach, ticket, pid}, :ok)

  @doc "Closes a ticket's hold."
  @spec release(term(), GenServer.server() | nil) :: :ok
  def release(ticket, server \\ __MODULE__), do: call(server, {:release, ticket}, :ok)

  @doc "Rebuilds holds for running entries (`%{issue:, pid:, started_at:}`) after an adoption."
  @spec rebuild([map()], keyword()) :: :ok
  def rebuild(entries, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    call(Keyword.get(opts, :server, __MODULE__), {:rebuild, entries, now, Keyword.get(opts, :capacity_policy, %{})}, :ok)
  end

  @doc false
  @spec ledger(GenServer.server()) :: Ledger.t() | nil
  def ledger(server \\ __MODULE__), do: call(server, :ledger, nil)

  @impl true
  def init(:ok), do: {:ok, %{ledger: Ledger.new(), monitors: %{}}}

  @impl true
  def handle_call({:policy_holds, candidates, readings}, _from, state) do
    ledger = Enum.reduce(candidates, state.ledger, &fold(&2, &1, Map.get(readings, Headroom.key(&1))))
    holds = for %{kind: :window, folded_at: nil} = h <- Map.values(ledger.holds), do: %{route: h.backend, account: h.account, estimate_percent: number(h.estimate)}
    {:reply, holds, %{state | ledger: ledger}}
  end

  def handle_call({:claim, issue, now, policy, owner}, _from, state) do
    case hold_attrs(state.ledger, issue, now, policy) do
      nil ->
        {:reply, :ok, state}

      {attrs, reserve} ->
        state = drop(state, attrs.ticket)

        case Ledger.claim(state.ledger, attrs, reading(state.ledger, {attrs.backend, attrs.account}), threshold: reserve || 0, fail_closed: reserve != nil) do
          {:allow, ledger} -> {:reply, :ok, watch(%{state | ledger: ledger}, attrs.ticket, owner)}
          {{:hold, reason}, _ledger} -> {:reply, {:hold, reason}, state}
        end
    end
  end

  def handle_call({:attach, ticket, pid}, _from, state) do
    state = if Map.has_key?(state.ledger.holds, ticket), do: watch(state, ticket, pid), else: state
    {:reply, :ok, state}
  end

  def handle_call({:release, ticket}, _from, state), do: {:reply, :ok, drop(state, ticket)}

  def handle_call({:rebuild, entries, now, policy}, _from, state) do
    state =
      Enum.reduce(entries, state, fn entry, acc ->
        # A restored start time that is not a DateTime counts from now, which only overstates the hold.
        started = if match?(%DateTime{}, entry[:started_at]), do: entry.started_at, else: now

        case {hold_attrs(acc.ledger, entry[:issue], started, policy), entry[:pid]} do
          {{attrs, _reserve}, pid} when is_pid(pid) -> watch(%{acc | ledger: Ledger.hold(acc.ledger, attrs)}, attrs.ticket, pid)
          _no_hold -> acc
        end
      end)

    {:reply, :ok, state}
  end

  def handle_call(:ledger, _from, state), do: {:reply, state.ledger, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.monitors, fn {_ticket, r} -> r == ref end) do
      {ticket, _ref} -> {:noreply, drop(state, ticket)}
      nil -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The hold attrs for a subscription dispatch and its reserve percent (nil when the account has none).
  defp hold_attrs(ledger, %{id: id, selected_backend: backend} = issue, %DateTime{} = at, policy) when is_binary(backend) do
    account = Map.get(issue, :selected_account) || "default"
    source = get_in(policy, [:sources, backend]) || %{}

    if Map.get(source, :billing) == "subscription" do
      {estimate, rate} = Ledger.window_estimate(Ledger.learned_burn(ledger, backend, account), Map.get(policy, :default_burn_percent_per_hour), @expected_hours)
      {%{ticket: id, backend: backend, account: account, kind: :window, estimate: estimate, rate: rate, created_at: at}, reserve(source, account)}
    end
  end

  defp hold_attrs(_ledger, _issue, _at, _policy), do: nil

  # Mirrors `Aiur.Capacity.Policy`'s reserve rule: a positive percent on a listed (or every) account.
  defp reserve(source, account) do
    percent = get_in(source, [:reserve, :percent]) || 0
    accounts = get_in(source, [:reserve, :accounts])
    if percent > 0 and (not is_list(accounts) or account in accounts), do: percent
  end

  defp reading(ledger, key) do
    case Map.get(ledger.readings, key) do
      %{used_percent: used, observed_at: at} -> %{remaining: 100 - used, observed_at: at}
      nil -> %{remaining: :unknown, observed_at: nil}
    end
  end

  defp watch(state, ticket, pid) do
    state = demonitor(state, ticket)
    %{state | monitors: Map.put(state.monitors, ticket, Process.monitor(pid))}
  end

  defp drop(state, ticket), do: %{demonitor(state, ticket) | ledger: Ledger.release(state.ledger, ticket)}

  defp demonitor(state, ticket) do
    {ref, monitors} = Map.pop(state.monitors, ticket)
    if ref, do: Process.demonitor(ref, [:flush])
    %{state | monitors: monitors}
  end

  defp fold(ledger, candidate, %{observed_at: %DateTime{} = at} = reading) do
    key = {candidate.backend, candidate.account || "default"}
    previous = Map.get(ledger.readings, key)

    case UsageFloor.remaining_percent(reading) do
      remaining when is_number(remaining) and (previous == nil or previous.observed_at != at) ->
        Ledger.observe_reading(ledger, elem(key, 0), elem(key, 1), %{used_percent: 100 - remaining, observed_at: at})

      _unchanged ->
        ledger
    end
  end

  defp fold(ledger, _candidate, _reading), do: ledger

  defp number(value) when is_number(value), do: value
  defp number(_unknown), do: nil

  defp call(nil, _message, default), do: default

  defp call(server, message, default) do
    if GenServer.whereis(server), do: GenServer.call(server, message), else: default
  catch
    :exit, _reason -> default
  end
end
