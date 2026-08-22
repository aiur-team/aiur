defmodule Aiur.BuildOrder.AdHocSource do
  @moduledoc """
  Supervised, in-memory poller for the derived **Ad Hoc** Build Order epic.

  The Ad Hoc epic is a runtime overlay of issues carrying the live
  `build-lane:adhoc` label — tickets created or promoted during a Build Order
  run. It is intentionally *not* part of the approved planning graph: the
  planning provider only fetches `build-order`-labelled roots and their graph
  members, so these issues never appear there.

  This source lists `build-lane:adhoc` issues (including closed
  ones, so merged/deferred/duplicate tickets stay visible), normalizes them to
  a compact snapshot, and broadcasts changes. It keeps the last successful
  snapshot as last-known-good and reports a named stale/unavailable status on
  failure — never an empty healthy overlay presented as fresh truth.

  The overlay is rendered separately and never contributes to the core
  completion denominator, complexity total, critical path, or feature ETA.

  It holds **no timer**. `Aiur.GitHub.ViewStateSweep` is the single view-state
  cadence and asks this source to reconcile; `refresh/1` covers a real demand in
  between. It does not yet read the store, so the sweep is currently the only
  thing that refreshes it.
  """

  use GenServer

  require Logger

  alias Aiur.BuildOrder.AdHocSource.Snapshot
  alias Aiur.GitHub.{Config, Issues, Transport}
  alias Aiur.Issue

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

  @doc "Requests an out-of-band refresh (async)."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.cast(server, :refresh)

  @doc "Synchronously refreshes and returns the resulting snapshot (test/support)."
  @spec refresh_sync(GenServer.server()) :: Snapshot.t()
  def refresh_sync(server \\ __MODULE__), do: GenServer.call(server, :refresh_sync)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      snapshot: %Snapshot{},
      # The first-page validator for the adhoc listing. Held here (not in the
      # store) because the listing is a repo collection with no single resource
      # identity, and because this GenServer owns the last-known-good snapshot a
      # `304` serves back.
      etag: nil,
      inflight: nil,
      task_supervisor: Keyword.get(opts, :task_supervisor, Aiur.TaskSupervisor),
      request_fun: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
      repo_fun: Keyword.get(opts, :repo_fun, &Transport.parse_repo/0),
      token_fun: Keyword.get(opts, :token_fun, &Transport.require_token/0),
      now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
      label_prefix: Keyword.get(opts, :label_prefix, safe_label_prefix())
    }

    if Keyword.get(opts, :poll_on_start, true), do: send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  def handle_call(:refresh_sync, _from, state) do
    state = apply_and_broadcast(state, fetch(state))
    {:reply, state.snapshot, state}
  end

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, ensure_fetch(state)}

  @impl true
  # No cadence of its own. `Aiur.GitHub.ViewStateSweep` is the only timer that
  # asks this source to reconcile.
  def handle_info(:poll, state), do: {:noreply, ensure_fetch(state)}

  def handle_info({ref, result}, %{inflight: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, apply_and_broadcast(%{state | inflight: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{inflight: ref} = state) do
    {:noreply, apply_and_broadcast(%{state | inflight: nil}, {:error, :task_down})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ensure_fetch(%{inflight: ref} = state) when is_reference(ref), do: state

  defp ensure_fetch(state) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, fn -> fetch(state) end)
    %{state | inflight: task.ref}
  end

  @spec fetch(map()) ::
          {:ok, [Snapshot.member()], String.t() | nil}
          | {:not_modified, String.t() | nil}
          | {:error, term()}
  defp fetch(state) do
    with {:ok, {owner, repo}} <- state.repo_fun.(),
         {:ok, token} <- state.token_fun.() do
      url =
        "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues?labels=#{URI.encode(@label)}&state=all&per_page=100"

      case fetch_pages(state.request_fun, url, token, owner, repo, state.label_prefix, state.etag, []) do
        {:ok, issues, etag} -> {:ok, issues |> Enum.map(&member/1) |> Enum.filter(&adhoc?/1), etag}
        {:not_modified, etag} -> {:not_modified, etag}
        {:error, _reason} = error -> error
      end
    end
  end

  # First page is conditional (the validator belongs to it); later pages ride
  # along unconditionally on a `200`. A `304` means the whole listing is
  # unchanged, so the caller serves its last-known-good snapshot. #2298 item 6:
  # the recurring repo-wide listing previously paid full price and carried no
  # `caller:`; now it revalidates for free and is attributed.
  defp fetch_pages(request_fun, url, token, owner, repo, prefix, etag, acc) do
    case request_fun.(adhoc_request(url, token, etag)) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        adhoc_page(request_fun, token, owner, repo, prefix, etag, acc, response, body)

      {:ok, %{status: 304}} ->
        {:not_modified, etag}

      {:ok, %{status: status}} ->
        Logger.warning("Ad Hoc overlay fetch failed status=#{status}")
        {:error, {:github_status, status}}

      {:error, reason} ->
        Logger.warning("Ad Hoc overlay fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp adhoc_request(url, token, etag) do
    request = %{method: :get, url: url, token: token, caller: "adhoc_source"}
    if is_binary(etag) and etag != "", do: Map.put(request, :etag, etag), else: request
  end

  defp adhoc_page(request_fun, token, owner, repo, prefix, etag, acc, response, body) do
    issues = Enum.map(body, &Issues.normalize_issue(&1, owner, repo, prefix))
    retained = Transport.header(Map.get(response, :headers, []), "etag") || etag

    case Transport.parse_next_page_url(Map.get(response, :headers, [])) do
      nil -> {:ok, acc ++ issues, retained}
      next_url -> fetch_pages_unconditional(request_fun, next_url, token, owner, repo, prefix, retained, acc ++ issues)
    end
  end

  defp fetch_pages_unconditional(request_fun, url, token, owner, repo, prefix, first_etag, acc) do
    case request_fun.(%{method: :get, url: url, token: token, caller: "adhoc_source"}) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        issues = Enum.map(body, &Issues.normalize_issue(&1, owner, repo, prefix))

        case Transport.parse_next_page_url(Map.get(response, :headers, [])) do
          nil -> {:ok, acc ++ issues, first_etag}
          next_url -> fetch_pages_unconditional(request_fun, next_url, token, owner, repo, prefix, first_etag, acc ++ issues)
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

  defp adhoc?(%{identity: nil}), do: false
  defp adhoc?(%{labels: labels}), do: @label in labels

  defp apply_result(state, {:ok, members, etag}) do
    generation = (state.snapshot.generation || 0) + 1

    snapshot = %Snapshot{
      status: :available,
      generation: generation,
      observed_at: now(state),
      members: Enum.sort_by(members, & &1.identifier)
    }

    %{state | snapshot: snapshot, etag: etag}
  end

  defp apply_result(%{snapshot: %Snapshot{generation: generation} = previous} = state, {:not_modified, etag})
       when is_integer(generation) do
    # The listing is unchanged: keep the held snapshot (back to :available if a
    # prior poll had gone stale) and refresh the validator.
    %{state | snapshot: %{previous | status: :available}, etag: etag}
  end

  # Unreachable with a validator held (a 304 implies a prior 200), but fail
  # closed rather than raise if it ever arrives.
  defp apply_result(state, {:not_modified, _etag}), do: %{state | snapshot: %Snapshot{status: :unavailable}}

  defp apply_result(%{snapshot: %Snapshot{generation: generation} = previous} = state, {:error, _reason})
       when is_integer(generation) do
    %{state | snapshot: %{previous | status: :stale}}
  end

  defp apply_result(state, {:error, _reason}) do
    %{state | snapshot: %Snapshot{status: :unavailable}}
  end

  defp apply_and_broadcast(state, result) do
    previous = state.snapshot
    state = apply_result(state, result)
    if meaningful(previous) != meaningful(state.snapshot), do: broadcast(state)
    state
  end

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

  defp safe_label_prefix do
    Config.label_prefix()
  rescue
    _error -> "aiur"
  catch
    _kind, _reason -> "aiur"
  end
end
