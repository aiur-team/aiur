defmodule Aiur.OpenTicketSource do
  @moduledoc """
  Supervised, in-memory poller for every open ticket on the repository.

  The orchestrator only ever sees the slice of the tracker it dispatches from:
  its candidate poll is scoped to the configured `agent:*` active-state labels,
  so an unlabelled ticket is invisible to every existing fleet surface. The
  Tickets panel needs the whole open backlog — including the tickets nobody has
  routed yet — which is exactly the set no other provider holds.

  This source lists open issues, keeps the last successful listing as
  last-known-good, and reports a named stale/unavailable status on failure rather
  than presenting an empty list as fresh truth. It is modelled on
  `Aiur.BuildOrder.AdHocSource`, which solves the same problem for the Ad Hoc
  overlay.

  It holds **no timer**. `Aiur.GitHub.ViewStateSweep` is the single view-state
  cadence and asks this source to reconcile only while a LiveView is watching
  it — the sweep skips any source with no demander, so an idle daemon with no
  dashboard session open makes no request from here at all. `refresh/1` covers
  a real demand in between. Three sources each running their own interval
  against one API is what this ticket exists to remove, and this listing in
  particular was the fastest unconditional full-backlog read in the system.

  Demand is registered by `subscribe/0`: every LiveView that shows the Tickets
  panel already subscribes, and the first subscriber also buys one immediate
  refresh, so opening the page renders the held snapshot and then the fresh
  listing. A monitor releases the demand when the session dies, so closing the
  last tab returns the source to the sweep's skip list.

  It does not yet read the store or subscribe to its change events, so the sweep
  is currently the only thing that refreshes it and a change made outside Aiur
  surfaces within one sweep interval. That latency is what the store
  subscription removes; this module's job here was removing the cost.
  """

  use GenServer

  require Logger

  alias Aiur.GitHub.{Config, Issues, RequestOrigin, Transport, ViewStateDemand}
  alias Aiur.Issue
  alias Aiur.OpenTicketSource.Snapshot

  @topic "open_tickets:changed"
  @max_pages 10
  # Issue bodies are large on a planning-heavy repository, so the response is
  # bounded rather than decoded in full.
  @max_response_bytes 4 * 1024 * 1024
  # The Tickets panel search matches descriptions as well as titles, and this
  # listing already carries every body on the wire — GitHub's REST issue list
  # returns `body` inline, so reading descriptions costs no extra request. That
  # is worth stating, because the Build Order catalog cannot do the same: its
  # GraphQL connection bills per parent, which is why a per-ticket body fetch
  # was avoided there. What descriptions do cost here is retained memory — this
  # poller holds the whole open backlog and broadcasts it to every subscribed
  # LiveView — so only the head of each body is kept. A ticket's summary lives
  # in its opening lines; the tail is checklists and logs, which make a search
  # noisier rather than better.
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

  @doc """
  Subscribes the caller to open-ticket change broadcasts and registers it as a
  demander.

  The demand half is what keeps the sweep's reconcile honest: with no demander
  the sweep skips this source entirely, so an idle daemon costs nothing.
  Registering the **first** demander triggers one refresh, so an opening page
  renders its held snapshot first and then receives the fresh listing.
  """
  @spec subscribe(GenServer.server()) :: :ok | {:error, term()}
  def subscribe(server \\ __MODULE__) do
    case Phoenix.PubSub.subscribe(Aiur.PubSub, @topic) do
      :ok ->
        GenServer.cast(server, {:demand, self()})
        :ok

      error ->
        error
    end
  end

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Whether any LiveView session is currently watching this source."
  @spec demanded?(GenServer.server()) :: boolean()
  def demanded?(server \\ __MODULE__) do
    GenServer.call(server, :demanded?)
  catch
    :exit, _reason -> false
  end

  @doc "The number of LiveView sessions currently watching this source."
  @spec demander_count(GenServer.server()) :: non_neg_integer()
  def demander_count(server \\ __MODULE__) do
    GenServer.call(server, :demander_count)
  catch
    :exit, _reason -> 0
  end

  @doc "Explicitly releases the caller's demand on this source."
  @spec undemand(GenServer.server()) :: :ok
  def undemand(server \\ __MODULE__), do: GenServer.cast(server, {:undemand, self()})

  @doc "Requests an out-of-band refresh (async)."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__),
    do: GenServer.cast(server, {:refresh, RequestOrigin.view_originated?()})

  @doc "Synchronously refreshes and returns the resulting snapshot (test/support)."
  @spec refresh_sync(GenServer.server()) :: Snapshot.t()
  def refresh_sync(server \\ __MODULE__), do: GenServer.call(server, :refresh_sync)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      snapshot: %Snapshot{},
      inflight: nil,
      demanders: MapSet.new(),
      demand_monitors: %{},
      task_supervisor: Keyword.get(opts, :task_supervisor, Aiur.TaskSupervisor),
      request_fun: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
      repo_fun: Keyword.get(opts, :repo_fun, &Transport.parse_repo/0),
      token_fun: Keyword.get(opts, :token_fun, &Transport.require_token/0),
      now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
      label_prefix: Keyword.get(opts, :label_prefix, safe_label_prefix()),
      github_fun: Keyword.get(opts, :github_fun, &github_tracker?/0)
    }

    if Keyword.get(opts, :poll_on_start, true), do: send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  def handle_call(:demanded?, _from, state), do: {:reply, ViewStateDemand.demanded?(state), state}

  def handle_call(:demander_count, _from, state), do: {:reply, ViewStateDemand.count(state), state}

  def handle_call(:refresh_sync, _from, state) do
    state = apply_and_broadcast(state, fetch(state))
    {:reply, state.snapshot, state}
  end

  @impl true
  def handle_cast({:demand, pid}, state) do
    {state, first?} = ViewStateDemand.demand(state, pid)
    # The first demander is the page opening: render held state, then buy the
    # fresh listing once. Later sessions coalesce on the in-flight guard, and
    # the sweep's cadence keeps the source current while it stays demanded.
    state = if first?, do: ensure_fetch(state, true), else: state
    {:noreply, state}
  end

  def handle_cast({:undemand, pid}, state), do: {:noreply, ViewStateDemand.undemand(state, pid)}

  def handle_cast({:refresh, view_originated?}, state),
    do: {:noreply, ensure_fetch(state, view_originated?)}

  @impl true
  # No cadence of its own. `Aiur.GitHub.ViewStateSweep` is the only timer that
  # asks this source to reconcile; `:poll` remains so a boot fill and an explicit
  # sweep both land on the same path.
  def handle_info(:poll, state), do: {:noreply, ensure_fetch(state, false)}

  def handle_info({ref, result}, %{inflight: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, apply_and_broadcast(%{state | inflight: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{inflight: ref} = state) do
    {:noreply, apply_and_broadcast(%{state | inflight: nil}, {:error, :task_down})}
  end

  # A demander's session process died: release its demand. Clauses above match
  # the in-flight task's own reference first; anything else reaching here that is
  # not a demander monitor is returned untouched by `handle_down/2`.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, ViewStateDemand.handle_down(state, ref)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ensure_fetch(%{inflight: ref} = state, _view_originated?) when is_reference(ref), do: state

  # Only the four provider funs and the label prefix cross into the task; passing
  # the whole state would copy the retained ticket list on every poll.
  defp ensure_fetch(state, view_originated?) do
    request = Map.take(state, [:repo_fun, :token_fun, :request_fun, :github_fun, :label_prefix])

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        RequestOrigin.carry(view_originated?, fn -> fetch(request) end)
      end)

    %{state | inflight: task.ref}
  end

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

  defp apply_result(state, {:ok, tickets, truncated?}) do
    generation = (state.snapshot.generation || 0) + 1

    snapshot = %Snapshot{
      status: :available,
      generation: generation,
      observed_at: now(state),
      truncated?: truncated?,
      tickets: Enum.sort_by(tickets, &sort_key/1)
    }

    %{state | snapshot: snapshot}
  end

  defp apply_result(state, :unsupported), do: %{state | snapshot: %Snapshot{status: :unsupported}}

  defp apply_result(%{snapshot: %Snapshot{generation: generation} = previous} = state, {:error, _reason})
       when is_integer(generation) do
    %{state | snapshot: %{previous | status: :stale}}
  end

  defp apply_result(state, {:error, _reason}) do
    %{state | snapshot: %Snapshot{status: :unavailable}}
  end

  # Newest ticket first, with the identifier as a total-order tiebreak so the
  # table never reshuffles between two equally-numbered reads.
  defp sort_key(%{identifier: identifier}) do
    case Integer.parse(to_string(identifier)) do
      {number, ""} -> {0, -number, ""}
      _other -> {1, 0, to_string(identifier)}
    end
  end

  defp apply_and_broadcast(state, result) do
    previous = state.snapshot
    state = apply_result(state, result)
    if meaningful(previous) != meaningful(state.snapshot), do: broadcast(state)
    state
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
