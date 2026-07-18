defmodule Aiur.BuildOrder.AdHocSource do
  @moduledoc """
  Supervised, in-memory poller for the derived **Ad Hoc** Build Order epic.

  The Ad Hoc epic is a runtime overlay of issues carrying the live
  `build-lane:adhoc` label — tickets created or promoted during a Build Order
  run. It is intentionally *not* part of the approved planning graph: the
  planning provider only fetches `build-order`-labelled roots and their graph
  members, so these issues never appear there.

  This poller periodically lists `build-lane:adhoc` issues (including closed
  ones, so merged/deferred/duplicate tickets stay visible), normalizes them to
  a compact snapshot, and broadcasts changes. It keeps the last successful
  snapshot as last-known-good and reports a named stale/unavailable status on
  failure — never an empty healthy overlay presented as fresh truth.

  The overlay is rendered separately and never contributes to the core
  completion denominator, complexity total, critical path, or feature ETA.
  """

  use GenServer

  require Logger

  alias Aiur.BuildOrder.AdHocSource.Snapshot
  alias Aiur.GitHub.{Config, Issues, Transport}
  alias Aiur.Issue

  @topic "build_order:adhoc:changed"
  @label "build-lane:adhoc"
  @default_interval :timer.seconds(60)

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
      inflight: nil,
      interval: Keyword.get(opts, :poll_interval, @default_interval),
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
    state = state |> apply_result(fetch(state)) |> broadcast()
    {:reply, state.snapshot, state}
  end

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, ensure_fetch(state)}

  @impl true
  def handle_info(:poll, state), do: {:noreply, state |> ensure_fetch() |> schedule_next()}

  def handle_info({ref, result}, %{inflight: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = %{state | inflight: nil} |> apply_result(result) |> broadcast()
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{inflight: ref} = state) do
    state = %{state | inflight: nil} |> apply_result({:error, :task_down}) |> broadcast()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ensure_fetch(%{inflight: ref} = state) when is_reference(ref), do: state

  defp ensure_fetch(state) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, fn -> fetch(state) end)
    %{state | inflight: task.ref}
  end

  defp schedule_next(state) do
    Process.send_after(self(), :poll, state.interval)
    state
  end

  @spec fetch(map()) :: {:ok, [Snapshot.member()]} | {:error, term()}
  defp fetch(state) do
    with {:ok, {owner, repo}} <- state.repo_fun.(),
         {:ok, token} <- state.token_fun.() do
      url =
        "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues?labels=#{URI.encode(@label)}&state=all&per_page=100"

      case fetch_pages(state.request_fun, url, token, owner, repo, state.label_prefix, []) do
        {:ok, issues} -> {:ok, issues |> Enum.map(&member/1) |> Enum.filter(&adhoc?/1)}
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

  defp adhoc?(%{identity: nil}), do: false
  defp adhoc?(%{labels: labels}), do: @label in labels

  defp apply_result(state, {:ok, members}) do
    generation = (state.snapshot.generation || 0) + 1

    snapshot = %Snapshot{
      status: :available,
      generation: generation,
      observed_at: now(state),
      members: Enum.sort_by(members, & &1.identifier)
    }

    %{state | snapshot: snapshot}
  end

  defp apply_result(%{snapshot: %Snapshot{generation: generation} = previous} = state, {:error, _reason})
       when is_integer(generation) do
    %{state | snapshot: %{previous | status: :stale}}
  end

  defp apply_result(state, {:error, _reason}) do
    %{state | snapshot: %Snapshot{status: :unavailable}}
  end

  defp broadcast(state) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, {:build_order_adhoc_updated, state.snapshot})
    end

    state
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
