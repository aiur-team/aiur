defmodule Aiur.GitHub.ViewStateSweep do
  @moduledoc """
  The single slow cadence behind view state: reconcile the one remaining
  writer, and run the issue-family divergence watermark that replaced the
  deleted polls' corroboration.

  ## Why exactly one timer, and why it is not zero

  Webhook deliveries are free and arrive first, so view state should ride on
  them and cost nothing. It cannot cost nothing, because **deliveries are lost**.
  Measured here: 9 of 100 deliveries returned 502 during a daemon restart,
  GitHub retried none of them, and none arrived later — 2 `issue_comment` and 7
  `check_run`. That is why the store is a cache with reconciliation and never
  the system of record, and it is the entire reason this timer exists.

  So the sweep has one job: **recover what a free writer did not deliver.** It
  is not a refresh cadence and it must never be tuned as though shortening it
  made anything fresher.

  ## What it sweeps, and the divergence watermark it runs

  `Aiur.OpenTicketSource` and `Aiur.BuildOrder.AdHocSource` are event-sourced
  (#2325): they subscribe to `Aiur.GitHub.ResourceStore` changes, keep one
  bootstrap listing per boot, and re-list when `Aiur.Webhooks.ModeRegistry`
  reports a repo `degraded` or `recovered` — the gap case where deliveries are
  known to be dropped. They hold no timer and are not swept.

  `Aiur.BuildOrder.PackStatus` remains. It is the "supervised writer for the
  daemon-owned `status.json` projection beside every discovered Build Order
  pack", and the planning contract names that file authoritative. Moving it to
  an event stream changes *when a file on disk is written*, which is a
  different risk class from the other three sources, so it is deliberately done
  in a separate PR. Until then it keeps the sweep as its recovery bound: a
  `status.json` entry whose delivery was lost is rewritten on the next tick.

  On the same cadence, the sweep runs the **divergence watermark** — the one
  steady-state GitHub read left in the view-state family. The polls #2325
  deleted were also the *poller corroboration* the silence sweep needs: without
  an independent observer of the issue family, `Aiur.Webhooks.DeliveryMode`
  could never tell "no events because nothing changed" from "no events because
  the webhook broke", so an `issues` delivery loss would never degrade the repo
  and the projections would sit frozen reporting `:available` forever. A single
  `updated_at`-ordered head page of the open-issue listing replaces that: it
  records activity corroboration through `Webhooks.record_activity/2`, and it
  compares GitHub's newest open-issue `updated_at` against the newest the store
  holds — when GitHub is ahead, a delivery was dropped and the view-state
  sources are told to re-list via `{:view_state_diverged, repo}`.

  ## What it replaced

  Three view-state sources each ran their own timer against GitHub, none of them
  with a config key an operator could reach:

    * `Aiur.OpenTicketSource` — the whole open backlog, every 120s
    * `Aiur.BuildOrder.AdHocSource` — a labelled issue listing, every 60s
    * `Aiur.BuildOrder.PackStatus` — a GraphQL pack read, every 300s

  Three independent cadences against one API, at three intervals nobody chose
  together, is how the burn this ticket exists to remove was built. Measured
  against GitHub's own `rateLimit { cost }`, each of those reads costs one point,
  so the three together were 1.7 requests per minute for state nobody was
  necessarily looking at. Two of the three are now event-sourced and cost
  nothing; PackStatus still reconciles on demand and through this process; and
  the divergence watermark is one page-1 head page per sweep — a bounded prefix,
  not a paged listing.

  ## Bounding the sweep rather than tightening it

  The sweep never skips itself, and it never advances a suppression watermark, so
  there is no window in which a gap cannot be seen. Suppression is decided per
  resource identity plus `version` (see `Aiur.GitHub.ResourceStore`), which is
  what lets a resource whose delivery was lost recover on the very next tick even
  though a newer sibling was delivered and marked.
  """

  use GenServer

  require Logger

  alias Aiur.Config
  alias Aiur.GitHub.{ResourceStore, Transport}
  alias Aiur.Webhooks

  # A source is anything holding view state that GitHub is the origin of. Named
  # here rather than self-registering, so the set of things that can generate
  # view-state traffic is readable in one place and a new one cannot be added
  # without this list changing.
  @sources [
    Aiur.BuildOrder.PackStatus
  ]

  @default_interval_ms :timer.minutes(15)
  # The divergence watermark is a single page of the open listing, so the same
  # bound the event-sourced open-ticket listing uses applies: an oversized repo
  # must not be decoded in full.
  @head_response_bytes 4 * 1024 * 1024
  @diverged_topic "view_state:diverged"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The sources this sweep reconciles."
  @spec sources() :: [module()]
  def sources, do: @sources

  @doc """
  Subscribes the caller to `{:view_state_diverged, repo}` broadcasts.

  The divergence watermark publishes this when it observes GitHub state newer
  than the store holds — the signal that a delivery was dropped and the
  event-sourced view-state sources must re-list. This is the replacement for
  the poller corroboration the deleted polls used to provide.
  """
  @spec subscribe_diverged() :: :ok | {:error, term()}
  def subscribe_diverged do
    Phoenix.PubSub.subscribe(Aiur.PubSub, @diverged_topic)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Runs one sweep now and answers the sources it reconciled (test/support)."
  @spec sweep_now(GenServer.server()) :: [module()]
  def sweep_now(server \\ __MODULE__) do
    GenServer.call(server, :sweep_now, 30_000)
  catch
    :exit, _reason -> []
  end

  @doc "The interval this sweep is running at, in milliseconds."
  @spec interval_ms(GenServer.server()) :: pos_integer() | nil
  def interval_ms(server \\ __MODULE__) do
    GenServer.call(server, :interval_ms)
  catch
    :exit, _reason -> nil
  end

  @impl true
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval_ms) || configured_interval_ms(),
      sources: Keyword.get(opts, :sources, @sources),
      repo_fun: Keyword.get(opts, :repo_fun, &Transport.parse_repo/0),
      token_fun: Keyword.get(opts, :token_fun, &Transport.require_token/0),
      request_fun: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
      # Resolved once at boot: the repository is a boot-time configuration fact,
      # and re-resolving it on every sweep would shell out to `git remote` on
      # each tick for no benefit.
      repo: nil,
      timer: nil
    }

    state = %{state | repo: resolve_repo(state.repo_fun)}
    if Keyword.get(opts, :sweep_on_start, false), do: send(self(), :sweep)
    {:ok, schedule(state)}
  end

  defp resolve_repo(repo_fun) do
    case repo_fun.() do
      {:ok, {owner, repo}} when is_binary(owner) and is_binary(repo) -> {String.downcase(owner), String.downcase(repo)}
      _other -> nil
    end
  end

  @impl true
  def handle_call(:sweep_now, _from, state), do: {:reply, sweep(state), state}
  def handle_call(:interval_ms, _from, state), do: {:reply, state.interval, state}
  def handle_call(:timer, _from, state), do: {:reply, state.timer, state}

  @impl true
  def handle_info(:sweep, state) do
    sweep(state)
    {:noreply, schedule(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A source that is not running is skipped rather than started: the sweep is
  # recovery for state somebody is holding, and there is nothing to recover for a
  # source this deployment does not run at all.
  defp sweep(state) do
    check_issue_head(state)

    Enum.filter(state.sources, fn source ->
      if Process.whereis(source) do
        source.refresh()
        true
      else
        false
      end
    end)
  end

  # -- divergence watermark ------------------------------------------------
  #
  # The one steady-state GitHub read left in the view-state family: a single
  # `updated_at`-ordered head page of the open-issue listing, run on the sweep's
  # own cadence. The deleted polls #2325 removed were also the corroboration the
  # silence sweep needs, so without this the repo could never degrade on an
  # `issues` delivery loss. It has two jobs:
  #
  # 1. Corroboration. `Webhooks.record_activity/2` feeds `DeliveryMode`, so
  #    `delivery_was_owed?/2` can fire again: the head advancing while a
  #    delivery did not land is exactly the "activity a full threshold after the
  #    last delivery" that proves a delivery was owed and lost.
  # 2. Divergence. GitHub's newest open-issue `updated_at` is compared against
  #    the newest the store holds; when GitHub is ahead, a delivery was dropped
  #    and the view-state sources re-list via `{:view_state_diverged, repo}`.
  #
  # Both are deliberately best-effort and quiet on failure: a missing repo or
  # token is a configuration fact, and a single failed head read should never
  # take the sweep — the PackStatus recovery bound — down with it.
  defp check_issue_head(%{repo: nil} = _state), do: :ok

  defp check_issue_head(%{repo: {owner, repo}} = state) do
    case state.token_fun.() do
      {:ok, token} ->
        url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues?state=open&sort=updated&direction=desc&per_page=100"

        case state.request_fun.(%{method: :get, url: url, token: token, max_response_bytes: @head_response_bytes}) do
          {:ok, %{status: 200, body: body}} when is_list(body) ->
            full_name = "#{owner}/#{repo}"
            head = newest_updated_at(body)
            record_head_activity(full_name, head)
            maybe_broadcast_divergence(full_name, head)

          _unexpected ->
            :ok
        end

      # A missing repo or token is a configuration fact, never a reason to take
      # the sweep down with it.
      _configuration_or_auth_fault ->
        :ok
    end
  rescue
    error ->
      Logger.warning("ViewStateSweep head check failed: #{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("ViewStateSweep head check exited: #{inspect(reason)}")
      :ok
  end

  defp newest_updated_at(body) do
    body
    |> Enum.map(&Map.get(&1, "updated_at"))
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.max(fn -> nil end)
  end

  # The observation key rides the head: a head that advanced is novel and records
  # activity; an unchanged head is a replay the registry ignores. A nil head (an
  # empty open listing) records nothing — an idle repo must not manufacture
  # corroboration for activity that never happened.
  defp record_head_activity(_full_name, nil), do: :ok

  defp record_head_activity(full_name, head) do
    Webhooks.record_activity(full_name, observation: {:issue_head, head})
    :ok
  end

  # Compare open-to-open: GitHub's newest open-issue `updated_at` against the
  # newest the store holds for an open issue, so a recently-closed issue (which
  # left the open head but may still hold a newer timestamp in the store) cannot
  # mask an open-issue divergence.
  defp maybe_broadcast_divergence(full_name, head) when is_binary(head) do
    case store_max_open_updated_at(full_name) do
      # Cold start: the store has no evidence of the repo yet, so there is
      # nothing to diverge from — the sources' boot listings establish the
      # baseline, and the next head check once deliveries have landed will.
      nil -> :ok
      store_max -> if head > store_max, do: broadcast_diverged(full_name)
    end
  end

  defp maybe_broadcast_divergence(_full_name, _head), do: :ok

  defp store_max_open_updated_at(full_name) do
    full_name
    |> then(&ResourceStore.list_type(:issue, &1))
    |> Enum.map(fn {_key, body} -> body end)
    |> Enum.filter(&(Map.get(&1, "state") == "open"))
    |> Enum.map(&Map.get(&1, "updated_at"))
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.max(fn -> nil end)
  end

  defp broadcast_diverged(full_name) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, @diverged_topic, {:view_state_diverged, full_name})
    end

    :ok
  rescue
    error -> Logger.warning("ViewStateSweep publish diverged failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("ViewStateSweep publish diverged exited: #{inspect(reason)}")
  end

  # Arming cancels first, so this process holds **at most one** timer no matter
  # how many paths reach it. That matters more than it looks: a boot that both
  # sent an immediate sweep and armed a delayed one would leave two permanent
  # timers, silently doubling the sweep rate and its cost, in the module whose
  # entire premise is that there is one. Holding the reference makes "one timer"
  # a property of the state rather than of every caller remembering.
  defp schedule(%{interval: interval} = state) when is_integer(interval) and interval > 0 do
    if is_reference(state.timer), do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :sweep, interval)}
  end

  defp schedule(state), do: %{state | timer: nil}

  # A configuration fault must not take the sweep down: without it a lost
  # delivery is unrecoverable, which is strictly worse than sweeping at the
  # default interval.
  defp configured_interval_ms do
    :timer.seconds(Config.view_state_sweep_seconds())
  rescue
    error ->
      Logger.warning("ViewStateSweep could not read its interval; using the default reason=#{inspect(error)}")
      @default_interval_ms
  catch
    _kind, _reason -> @default_interval_ms
  end
end
