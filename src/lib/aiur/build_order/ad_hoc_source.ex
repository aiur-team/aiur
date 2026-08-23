defmodule Aiur.BuildOrder.AdHocSource do
  @moduledoc """
  Event-sourced projection of the derived **Ad Hoc** Build Order epic.

  The Ad Hoc epic is a runtime overlay of issues carrying the live
  `build-lane:adhoc` label — tickets created or promoted during a Build Order
  run. It is intentionally *not* part of the approved planning graph: the
  planning provider only fetches `build-order`-labelled roots and their graph
  members, so these issues never appear there.

  ## Where the overlay comes from now

  The source used to poll GitHub for the labelled listing on a timer. Every
  issue's state and label set is now already deposited in
  `Aiur.GitHub.ResourceStore` by the `issues` webhook delivery (`labeled`,
  `unlabeled`, `opened`, `closed`, `reopened`, `edited`, `deleted`,
  `transferred`) **before** the event is published — see
  `Aiur.Events.GithubWebhook.Deposit` — and Aiur's own label mutations write
  through the same store. So this source subscribes to `:issue` and
  `:issue_labels` store changes and maintains the overlay from that event
  stream, no listing required in steady state.

  **Keep exactly one listing per boot**: a bootstrap read (labelled issues,
  open *and* closed, so merged/deferred/duplicate tickets stay visible)
  establishes the baseline the event stream then maintains. Re-listing also
  happens when `Aiur.Webhooks.ModeRegistry` reports the repository `degraded`
  — the one case where deliveries are known to be dropped — when it reports
  `recovered` (the trailing edge, where the gap's dropped deliveries are
  re-read), and on an explicit `refresh/1`. That is gap-based re-convergence,
  never a clock.

  It holds **no timer** and performs **no GitHub reads** in steady state.
  `Aiur.GitHub.ViewStateSweep` does not sweep it; the event stream is the
  refresh. The one steady-state read left anywhere is the low-frequency
  divergence watermark `Aiur.GitHub.ViewStateSweep` runs — a single cheap
  `updated_at`-ordered head page that records poller corroboration for the
  issue family (so webhook loss can still degrade the repo) and re-lists the
  sources when GitHub is ahead of the store.

  The overlay is rendered separately and never contributes to the core
  completion denominator, complexity total, critical path, or feature ETA.
  """

  use GenServer

  require Logger

  alias Aiur.BuildOrder.AdHocSource.Snapshot
  alias Aiur.GitHub.{Config, Issues, ResourceStore, Transport, ViewStateSweep}
  alias Aiur.Issue
  alias Aiur.Webhooks.ModeRegistry

  @topic "build_order:adhoc:changed"
  @label "build-lane:adhoc"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Returns the current Ad Hoc overlay snapshot."
  @spec snapshot(GenServer.server()) :: Snapshot.t()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @doc "Subscribes the caller to Ad Hoc overlay change broadcasts."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, @topic)

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Requests an out-of-band re-list (async)."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.cast(server, :refresh)

  @doc "Synchronously re-lists and returns the resulting snapshot (test/support)."
  @spec refresh_sync(GenServer.server()) :: Snapshot.t()
  def refresh_sync(server \\ __MODULE__), do: GenServer.call(server, :refresh_sync)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      snapshot: %Snapshot{},
      # The projection: issue number (string) => member. The event stream
      # reconciles one entry at a time; the snapshot is derived from this map.
      members: %{},
      # Whether a bootstrap listing has ever succeeded. Only a successful listing
      # establishes that the projection is complete; until one lands — or after
      # one fails — the projection may be missing events the stream never carried,
      # and a store event must not upgrade it back to `:available`.
      baseline_ok?: false,
      repo: nil,
      request_fun: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
      repo_fun: Keyword.get(opts, :repo_fun, &Transport.parse_repo/0),
      token_fun: Keyword.get(opts, :token_fun, &Transport.require_token/0),
      now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
      label_prefix: Keyword.get(opts, :label_prefix, safe_label_prefix())
    }

    state = %{state | repo: resolve_repo(state.repo_fun)}
    subscribe_to_events()
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
  # newer event, which is the exact divergence this design exists to prevent.
  def handle_cast(:refresh, state) do
    {:noreply, apply_result(state, fetch(state))}
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
  # deposits the issue body before publishing, so the current body is already
  # in local memory when this runs — reconcile exactly that issue, no listing.
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
        remove_member(state, id)

      _change ->
        case ResourceStore.data(ResourceStore.key(:issue, owner, repo, id)) do
          # A labels-only mutation on an issue the store never held. The
          # projection still holds the member, so reconcile it from the label
          # set alone rather than dropping it because the store lacks a body it
          # may never have had.
          nil -> update_held_member(state, id)
          _gh_issue -> apply_issue_change(state, id)
        end
    end
  end

  defp reconcile_issue(state, _owner, _repo, _id, _change), do: state

  defp apply_issue_change(%{repo: {owner, repo}} = state, id) do
    case ResourceStore.data(ResourceStore.key(:issue, owner, repo, id)) do
      nil ->
        remove_member(state, id)

      gh_issue ->
        issue = Issues.normalize_issue(gh_issue, owner, repo, state.label_prefix)

        if adhoc?(issue) do
          upsert_member(state, issue)
        else
          remove_member(state, id)
        end
    end
  end

  # The `:issue_labels` body is GitHub's own labels array. Membership is
  # label-defined, so a held member can be reconciled from the label set alone
  # even when the store holds no issue body for it.
  defp update_held_member(%{repo: {owner, repo}} = state, id) do
    case Map.fetch(state.members, id) do
      {:ok, member} ->
        labels = label_names(ResourceStore.data(ResourceStore.key(:issue_labels, owner, repo, id)))

        if @label in labels do
          %{state | members: Map.put(state.members, id, %{member | labels: labels})}
          |> apply_members()
        else
          remove_member(state, id)
        end

      :error ->
        state
    end
  end

  defp label_names(labels) when is_list(labels) do
    Enum.map(labels, &String.downcase(Map.get(&1, "name") || ""))
  end

  defp label_names(_labels), do: []

  defp upsert_member(state, %Issue{} = issue) do
    member = member(issue)

    %{state | members: Map.put(state.members, member.identifier, member)}
    |> apply_members()
  end

  defp remove_member(state, id) do
    if Map.has_key?(state.members, id) do
      %{state | members: Map.delete(state.members, id)}
      |> apply_members()
    else
      state
    end
  end

  # Rebuild the snapshot from the projection map. A store event that does not
  # change the projected content (an `:issue_labels` wake arriving after the
  # same delivery's `:issue` wake already applied it) neither bumps the
  # generation nor wakes subscribers.
  defp apply_members(state) do
    previous = state.snapshot
    state = rebuild_snapshot(state)
    if meaningful(previous) != meaningful(state.snapshot), do: broadcast(state)
    state
  end

  # -- bootstrap listing ----------------------------------------------------

  @spec fetch(map()) :: {:ok, [Snapshot.member()]} | {:error, term()}
  defp fetch(state) do
    with {:ok, {owner, repo}} <- state.repo_fun.(),
         {:ok, token} <- state.token_fun.() do
      url =
        "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues?labels=#{URI.encode(@label)}&state=all&per_page=100"

      case fetch_pages(state.request_fun, url, token, owner, repo, state.label_prefix, []) do
        {:ok, issues} -> {:ok, issues |> Enum.filter(&adhoc?/1) |> Enum.map(&member/1)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp fetch_pages(request_fun, url, token, owner, repo, prefix, acc) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        issues = Enum.map(body, &Issues.normalize_issue(&1, owner, repo, prefix))

        case Transport.parse_next_page_url(Map.get(response, :headers, [])) do
          nil -> {:ok, acc ++ issues}
          next_url -> fetch_pages(request_fun, next_url, token, owner, repo, prefix, acc ++ issues)
        end

      {:ok, %{status: status}} ->
        Logger.warning("Ad Hoc overlay fetch failed status=#{status}")
        {:error, {:github_status, status}}

      {:error, reason} ->
        Logger.warning("Ad Hoc overlay fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp member(%Issue{} = issue) do
    %{
      identity: issue.tracker_identity,
      identifier: issue.identifier,
      title: issue.title,
      url: issue.url,
      lifecycle: lifecycle(issue.state),
      labels: List.wrap(issue.labels)
    }
  end

  defp lifecycle("Closed"), do: :closed
  defp lifecycle(_state), do: :open

  # A member whose `tracker_identity` is nil must never enter the overlay: the
  # downstream projection joins members to execution/progress/activity by
  # identity, and a nil one is unjoinable. This clause is defense-in-depth
  # matching the pre-#2325 contract — `Issues.normalize_issue/4` always assigns
  # a joinable or unjoinable struct, so a nil identity cannot reach the listing
  # or the event path today, but a future construction that skips normalization
  # must not silently enter the overlay.
  defp adhoc?(%Issue{tracker_identity: nil}), do: false
  defp adhoc?(%Issue{labels: labels}), do: @label in List.wrap(labels)

  # -- snapshot plumbing ----------------------------------------------------

  defp apply_result(state, result) do
    previous = state.snapshot
    state = do_apply_result(state, result)
    if meaningful(previous) != meaningful(state.snapshot), do: broadcast(state)
    state
  end

  defp do_apply_result(state, {:ok, members}) do
    %{state | members: Map.new(members, &{&1.identifier, &1}), baseline_ok?: true}
    |> rebuild_snapshot()
  end

  # A failed listing drops the baseline flag. The projection may now be missing
  # events the stream did not carry, so no subsequent store event may claim
  # `:available` again. Last-known-good content is retained and reported
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
          members: state.members |> Map.values() |> Enum.sort_by(& &1.identifier)
        }
    }
  end

  # Only a successful listing establishes that the projection is complete.
  # Until one lands — or after one fails — the projection may be missing events
  # the stream never carried, so it reports `:stale` while it holds content and
  # `:unavailable` while it holds none.
  defp snapshot_status(%{baseline_ok?: true}), do: :available
  defp snapshot_status(%{baseline_ok?: false, members: members}) when map_size(members) > 0, do: :stale
  defp snapshot_status(_state), do: :unavailable

  # Ignore observed_at/generation churn: only status or membership changes warrant
  # waking subscribed LiveViews to reload.
  defp meaningful(%Snapshot{status: status, members: members}), do: {status, members}

  defp broadcast(state) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, {:build_order_adhoc_updated, state.snapshot})
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

  defp safe_label_prefix do
    Config.label_prefix()
  rescue
    _error -> "aiur"
  catch
    _kind, _reason -> "aiur"
  end
end
