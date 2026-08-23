defmodule Aiur.OpenTicketSource do
  @moduledoc """
  Event-sourced projection of every open ticket on the repository.

  The orchestrator only ever sees the slice of the tracker it dispatches from:
  its candidate poll is scoped to the configured `agent:*` active-state labels,
  so an unlabelled ticket is invisible to every existing fleet surface. The
  Tickets panel needs the whole open backlog — including the tickets nobody has
  routed yet — which is exactly the set no other provider holds.

  ## Where the backlog comes from now

  The source used to poll GitHub for the open listing on a timer. Every
  ticket's state is now already deposited in `Aiur.GitHub.ResourceStore` by the
  `issues` webhook delivery (`opened`, `closed`, `reopened`, `labeled`,
  `unlabeled`, `edited`, `deleted`, `transferred`) **before** the event is
  published — see `Aiur.Events.GithubWebhook.Deposit` — and Aiur's own label
  and ticket mutations write through the same store. So this source subscribes
  to `:issue` and `:issue_labels` store changes and maintains the whole open
  backlog from that event stream, no listing required in steady state.

  **Keep exactly one listing per boot**: a bootstrap read establishes the
  baseline the event stream then maintains, so a restart never starts empty.
  Re-listing also happens when `Aiur.Webhooks.ModeRegistry` reports the
  repository `degraded` — the one case where deliveries are known to be dropped
  — when it reports `recovered` (the trailing edge, where the gap's dropped
  deliveries are re-read), and on an explicit `refresh/1` (a real demand, e.g.
  after the dashboard's own mutation). That is gap-based re-convergence, never a
  clock.

  It holds **no timer** and performs **no GitHub reads** in steady state.
  `Aiur.GitHub.ViewStateSweep` does not sweep it; the event stream is the
  refresh. The one steady-state read left anywhere is the low-frequency
  divergence watermark `Aiur.GitHub.ViewStateSweep` runs — a single cheap
  `updated_at`-ordered head page that records poller corroboration for the
  issue family (so webhook loss can still degrade the repo) and re-lists the
  sources when GitHub is ahead of the store.

  The projection keeps the last successful listing as last-known-good and
  reports a named stale/unavailable status on failure rather than presenting an
  empty list as fresh truth. Only a successful listing marks the projection
  `:available`; a failed listing leaves it `:stale`/`:unavailable` until the
  next one succeeds, no matter how many store events arrive in between. It is
  modelled on `Aiur.BuildOrder.AdHocSource`, which solves the same problem for
  the Ad Hoc overlay.
  """

  use GenServer

  require Logger

  alias Aiur.GitHub.{Config, Issues, RequestOrigin, ResourceStore, Transport, ViewStateSweep}
  alias Aiur.Issue
  alias Aiur.OpenTicketSource.Snapshot
  alias Aiur.Webhooks.ModeRegistry

  @topic "open_tickets:changed"
  @max_pages 10
  # Issue bodies are large on a planning-heavy repository, so the bootstrap
  # response is bounded rather than decoded in full.
  @max_response_bytes 4 * 1024 * 1024
  # The Tickets panel search matches descriptions as well as titles, and the
  # listing already carries every body on the wire — GitHub's REST issue list
  # returns `body` inline, so reading descriptions costs no extra request. Only
  # the head of each body is kept: this projection broadcasts to every
  # subscribed LiveView, so a ticket's summary lives in its opening lines and
  # the tail (checklists and logs) makes a search noisier rather than better.
  @body_excerpt_chars 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Returns the current open-ticket snapshot."
  @spec snapshot(GenServer.server()) :: Snapshot.t()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  catch
    :exit, _reason -> %Snapshot{}
  end

  @doc "Subscribes the caller to open-ticket change broadcasts."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, @topic)

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Requests an out-of-band re-list (async)."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__),
    do: GenServer.cast(server, {:refresh, RequestOrigin.view_originated?()})

  @doc "Synchronously re-lists and returns the resulting snapshot (test/support)."
  @spec refresh_sync(GenServer.server()) :: Snapshot.t()
  def refresh_sync(server \\ __MODULE__), do: GenServer.call(server, :refresh_sync)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      snapshot: %Snapshot{},
      # The projection: issue number (string) => ticket. The event stream
      # reconciles one entry at a time; the snapshot is derived from this map.
      tickets: %{},
      # Whether a bootstrap listing has ever succeeded. Only a successful listing
      # establishes that the projection is complete; until one lands — or after
      # one fails — the projection may be missing events the stream never carried,
      # and a store event must not upgrade it back to `:available`.
      baseline_ok?: false,
      truncated?: false,
      repo: nil,
      request_fun: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
      repo_fun: Keyword.get(opts, :repo_fun, &Transport.parse_repo/0),
      token_fun: Keyword.get(opts, :token_fun, &Transport.require_token/0),
      now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
      label_prefix: Keyword.get(opts, :label_prefix, safe_label_prefix()),
      github_fun: Keyword.get(opts, :github_fun, &github_tracker?/0)
    }

    state = %{state | repo: resolve_repo(state.repo_fun)}
    if state.github_fun.(), do: subscribe_to_events()
    if Keyword.get(opts, :poll_on_start, true), do: send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  def handle_call(:refresh_sync, _from, state) do
    state = apply_result(state, fetch(state))
    {:reply, state.snapshot, state}
  end

  @impl true
  # A demand re-list. Applied synchronously in this process, so a store event
  # that arrives while the listing is in flight is queued behind it and applied
  # after — a listing is a GitHub snapshot taken before the event, so the event
  # must win. An async task would let the listing's stale full-set overwrite a
  # newer event (a ticket opened between the listing snapshot and its
  # application would be dropped), which is the exact divergence this design
  # exists to prevent.
  def handle_cast({:refresh, view_originated?}, state) do
    {:noreply, apply_result(state, RequestOrigin.carry(view_originated?, fn -> fetch(state) end))}
  end

  @impl true
  # The boot fill, applied synchronously for the same reason as `refresh/1`:
  # the one listing per boot is the baseline, and the event stream maintains
  # it. `ViewStateSweep` no longer sweeps this source.
  def handle_info(:poll, state) do
    {:noreply, apply_result(state, fetch(state))}
  end

  # The gap-based re-convergence: deliveries are known to be dropped while the
  # repo is degraded, so re-list to re-establish the baseline. ModeRegistry
  # re-publishes this on every sweep while the repo stays degraded, so the
  # re-list is a coarse cadence that only runs during the outage itself.
  def handle_info({:webhook_degraded, repo}, state), do: {:noreply, maybe_relist(state, repo)}

  # The trailing edge: a resumed delivery proves the gap has closed, so re-list
  # once to recover everything that changed during the degraded window.
  def handle_info({:webhook_recovered, repo}, state), do: {:noreply, maybe_relist(state, repo)}

  # The divergence watermark (Aiur.GitHub.ViewStateSweep): a low-frequency head
  # check observed GitHub state newer than what the store holds, so a delivery
  # was dropped and the projection must re-list to re-converge.
  def handle_info({:view_state_diverged, repo}, state), do: {:noreply, maybe_relist(state, repo)}

  # A store change for the source's repository. Every `issues` delivery
  # deposits the issue body before publishing, and Aiur's own mutations write
  # through the same store, so the current body is already in local memory when
  # this runs — reconcile exactly that ticket, no listing.
  def handle_info({:github_resource_changed, %{key: {type, owner, repo, id}} = change}, state)
      when type in [:issue, :issue_labels] do
    {:noreply, reconcile_issue(state, owner, repo, id, change)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- event-stream projection ---------------------------------------------

  # The `:issue` and `:issue_labels` type subscriptions are repo-wide, so a
  # multi-repo fleet delivers other repos' issues here; only the source's own
  # repository is reconciled.
  defp reconcile_issue(%{repo: {owner, repo}} = state, owner, repo, id, change) do
    case change do
      # A deleted issue drops both its issue body and its label set; nothing
      # else publishes a change with no body held. The store's own retention
      # eviction is silent and never reaches here.
      %{data?: false} ->
        remove_ticket(state, id)

      _change ->
        case ResourceStore.data(ResourceStore.key(:issue, owner, repo, id)) do
          # A labels-only mutation on an issue the store never held (no webhook
          # has deposited it and the boot listing does not write through). The
          # projection still holds the ticket, so keep it and refresh its labels
          # rather than dropping an open ticket because the store lacks a body
          # it may never have had.
          nil -> update_held_labels(state, id)
          _gh_issue -> apply_issue_change(state, id)
        end
    end
  end

  defp reconcile_issue(state, _owner, _repo, _id, _change), do: state

  defp apply_issue_change(%{repo: {owner, repo}} = state, id) do
    case ResourceStore.data(ResourceStore.key(:issue, owner, repo, id)) do
      nil ->
        remove_ticket(state, id)

      gh_issue ->
        cond do
          # GitHub serves pull requests from the issues endpoint; only a
          # `pull_request` key distinguishes them, and the Tickets panel is
          # about tickets.
          pull_request?(gh_issue) -> remove_ticket(state, id)
          Map.get(gh_issue, "state") != "open" -> remove_ticket(state, id)
          true -> upsert_ticket(state, Issues.normalize_issue(gh_issue, owner, repo, state.label_prefix))
        end
    end
  end

  # The `:issue_labels` body is GitHub's own labels array; it lets a held
  # ticket's labels refresh even when the store holds no issue body for it.
  defp update_held_labels(%{repo: {owner, repo}} = state, id) do
    case Map.fetch(state.tickets, id) do
      {:ok, ticket} ->
        labels = label_names(ResourceStore.data(ResourceStore.key(:issue_labels, owner, repo, id)))

        %{state | tickets: Map.put(state.tickets, id, %{ticket | labels: labels})}
        |> apply_tickets()

      :error ->
        state
    end
  end

  defp label_names(labels) when is_list(labels) do
    Enum.map(labels, &String.downcase(Map.get(&1, "name") || ""))
  end

  defp label_names(_labels), do: []

  defp upsert_ticket(state, %Issue{} = issue) do
    ticket = ticket(issue)

    %{state | tickets: Map.put(state.tickets, ticket.identifier, ticket)}
    |> apply_tickets()
  end

  defp remove_ticket(state, id) do
    if Map.has_key?(state.tickets, id) do
      %{state | tickets: Map.delete(state.tickets, id)}
      |> apply_tickets()
    else
      state
    end
  end

  # Rebuild the snapshot from the projection map. A store event that does not
  # change the projected content (an `:issue_labels` wake arriving after the
  # same delivery's `:issue` wake already applied it) neither bumps the
  # generation nor wakes subscribers.
  defp apply_tickets(state) do
    previous = state.snapshot
    state = rebuild_snapshot(state)
    if meaningful(previous) != meaningful(state.snapshot), do: broadcast(state)
    state
  end

  # -- bootstrap listing ----------------------------------------------------

  @spec fetch(map()) :: {:ok, [Snapshot.ticket()], boolean()} | {:error, term()} | :unsupported
  defp fetch(state) do
    if state.github_fun.() do
      github_fetch(state)
    else
      :unsupported
    end
  end

  defp github_fetch(state) do
    with {:ok, {owner, repo}} <- state.repo_fun.(),
         {:ok, token} <- state.token_fun.() do
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues?state=open&per_page=100"
      fetch_pages(state, url, token, owner, repo, [], @max_pages)
    else
      # A missing repo or token is a configuration fault, and every other failure
      # path here says why in the log; this one must not be the silent exception.
      {:error, reason} ->
        Logger.warning("Open ticket listing unavailable: #{inspect(reason)}")
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp fetch_pages(_state, _url, _token, _owner, _repo, acc, 0), do: {:ok, flatten(acc), true}

  defp fetch_pages(state, url, token, owner, repo, acc, pages_left) do
    request = %{method: :get, url: url, token: token, max_response_bytes: @max_response_bytes}

    case state.request_fun.(request) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        tickets =
          body
          |> Enum.reject(&pull_request?/1)
          |> Enum.map(&ticket(Issues.normalize_issue(&1, owner, repo, state.label_prefix)))

        case Transport.parse_next_page_url(Map.get(response, :headers, [])) do
          nil -> {:ok, flatten([tickets | acc]), false}
          next_url -> fetch_pages(state, next_url, token, owner, repo, [tickets | acc], pages_left - 1)
        end

      {:ok, %{status: status}} ->
        Logger.warning("Open ticket listing failed status=#{status}")
        {:error, {:github_status, status}}

      {:error, reason} ->
        Logger.warning("Open ticket listing failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp flatten(pages), do: pages |> Enum.reverse() |> Enum.concat()

  # GitHub serves pull requests from the issues endpoint; only a `pull_request`
  # key distinguishes them, and the Tickets panel is about tickets.
  defp pull_request?(gh_issue) when is_map(gh_issue), do: is_map(Map.get(gh_issue, "pull_request"))
  defp pull_request?(_gh_issue), do: false

  defp ticket(%Issue{} = issue) do
    %{
      identity: issue.tracker_identity,
      identifier: issue.identifier,
      title: issue.title,
      body_excerpt: body_excerpt(issue.description),
      url: issue.url,
      state: issue.state,
      labels: List.wrap(issue.labels),
      assignee: issue.assignee_id,
      created_at: issue.created_at,
      updated_at: issue.updated_at
    }
  end

  defp body_excerpt(description) when is_binary(description) do
    case description |> String.slice(0, @body_excerpt_chars) |> String.trim() do
      "" ->
        nil

      # `String.slice/3` and `String.trim/1` both return sub-binaries, which
      # keep the *whole* body alive behind a 1000-character window. Copying is
      # what actually applies the bound this design rests on.
      excerpt ->
        :binary.copy(excerpt)
    end
  end

  defp body_excerpt(_description), do: nil

  # -- snapshot plumbing ----------------------------------------------------

  defp apply_result(state, result) do
    previous = state.snapshot
    state = do_apply_result(state, result)
    if meaningful(previous) != meaningful(state.snapshot), do: broadcast(state)
    state
  end

  defp do_apply_result(state, {:ok, tickets, truncated?}) do
    %{state | tickets: Map.new(tickets, &{&1.identifier, &1}), truncated?: truncated?, baseline_ok?: true}
    |> rebuild_snapshot()
  end

  defp do_apply_result(state, :unsupported) do
    %{state | snapshot: %Snapshot{status: :unsupported}, tickets: %{}}
  end

  # A failed listing drops the baseline flag. The projection may now be missing
  # events the stream did not carry, so no subsequent store event may claim
  # `:available` again — that is exactly how "an empty list presented as fresh
  # truth" used to happen. Last-known-good content is retained and reported
  # `:stale` rather than being dressed up as current.
  defp do_apply_result(state, {:error, _reason}) do
    %{state | baseline_ok?: false}
    |> rebuild_snapshot()
  end

  # The projection map -> a snapshot. Status is decided by `snapshot_status/1`:
  # the map is maintained from the event stream, but only a successful listing
  # proves the map is complete, so a projection whose baseline has never landed
  # (or whose re-list failed) stays `:stale`/`:unavailable` no matter how many
  # store events arrive.
  defp rebuild_snapshot(state) do
    %{
      state
      | snapshot: %Snapshot{
          status: snapshot_status(state),
          generation: (state.snapshot.generation || 0) + 1,
          observed_at: now(state),
          truncated?: state.truncated?,
          tickets: state.tickets |> Map.values() |> Enum.sort_by(&sort_key/1)
        }
    }
  end

  # Only a successful listing establishes that the projection is complete.
  # Until one lands — or after one fails — the projection may be missing events
  # the stream never carried, so it reports `:stale` while it holds content and
  # `:unavailable` while it holds none.
  defp snapshot_status(%{baseline_ok?: true}), do: :available
  defp snapshot_status(%{baseline_ok?: false, tickets: tickets}) when map_size(tickets) > 0, do: :stale
  defp snapshot_status(_state), do: :unavailable

  # Newest ticket first, with the identifier as a total-order tiebreak so the
  # table never reshuffles between two equally-numbered reads.
  defp sort_key(%{identifier: identifier}) do
    case Integer.parse(to_string(identifier)) do
      {number, ""} -> {0, -number, ""}
      _other -> {1, 0, to_string(identifier)}
    end
  end

  # Ignore observed_at/generation churn: only status or ticket changes warrant
  # waking subscribed LiveViews to reload. Descriptions are excluded on purpose
  # — an edited issue body changes what the panel *matches*, never what it
  # *shows*, and waking every dashboard for a checklist tick would make prose
  # churn on a planning-heavy repository indistinguishable from real work
  # arriving. The next real change carries the new excerpt along with it.
  defp meaningful(%Snapshot{status: status, tickets: tickets}) do
    {status, Enum.map(tickets, &Map.delete(&1, :body_excerpt))}
  end

  defp broadcast(state) do
    if Process.whereis(Aiur.PubSub) do
      # Only the generation travels: every subscriber uses it to decide whether
      # to reload and then reads the snapshot itself, so the full listing — now
      # carrying an excerpt per ticket — is not copied into each of them.
      payload = %{generation: state.snapshot.generation, status: state.snapshot.status}
      Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, {:open_tickets_updated, payload})
    end

    :ok
  end

  defp now(state) do
    case state.now_fun.() do
      %DateTime{} = datetime -> datetime
      _other -> nil
    end
  end

  # -- subscriptions and delivery mode --------------------------------------

  defp subscribe_to_events do
    ResourceStore.subscribe(:issue)
    ResourceStore.subscribe(:issue_labels)
    ModeRegistry.subscribe()
    ModeRegistry.subscribe_recovered()
    ViewStateSweep.subscribe_diverged()
    :ok
  end

  defp maybe_relist(%{repo: {owner, repo}} = state, degraded_repo) do
    if String.downcase(degraded_repo) == "#{owner}/#{repo}" do
      apply_result(state, fetch(state))
    else
      state
    end
  end

  defp maybe_relist(state, _degraded_repo), do: state

  defp resolve_repo(repo_fun) do
    case repo_fun.() do
      {:ok, {owner, repo}} when is_binary(owner) and is_binary(repo) -> {String.downcase(owner), String.downcase(repo)}
      _other -> nil
    end
  end

  # This listing is a GitHub REST call, so a Linear or in-memory tracker has no
  # such source. Reporting that as an outage would present a configuration fact
  # as a fault the operator could fix by retrying.
  defp github_tracker? do
    Aiur.Config.tracker_kind() == "github"
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp safe_label_prefix do
    Config.label_prefix()
  rescue
    _error -> "aiur"
  catch
    _kind, _reason -> "aiur"
  end
end
