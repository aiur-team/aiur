defmodule Aiur.Opencode.AttachQueue do
  @moduledoc """
  Single-inflight background attach orchestrator. Enumerates the agent
  identifier list and runs `Aiur.Opencode.AgentAttach.attach/2` one at
  a time so each agent ends up with a persistent opencode-attach pane
  in the hidden tmux window.

  ## API

  - `enqueue/1` adds an identifier to the back of the queue.
  - `request_priority/1` jumps an identifier to the front. If the
    requested identifier is already in flight, the request is honored
    by emitting a `:pane_priority_attached` PubSub event once the
    in-flight attach finishes (PaneManager listens for it and promotes
    the pane to the visible window). If it has not started yet, it
    becomes the next inflight task.
  - `cancel/1` records a cancellation so the attach result lands in
    `:hidden` and does NOT get promoted. Used by `PaneManager` when the
    user closes a pane that was still mid-attach.

  ## Boot

  Subscribes to `Aiur.Opencode.WarmServer`'s `:warm_server_ready` event
  to learn `base_url`. Subscribes to `AgentPubSub` running changes so
  newly-spawned agents auto-enqueue.

  ## Events emitted

  - `{:pane_attached, identifier}` — attach completed, pane is `:hidden`.
  - `{:pane_priority_attached, identifier}` — attach completed AND the
    caller had requested priority; PaneManager should promote.
  - `{:pane_attach_failed, identifier, reason}` — attach errored.

  All on `Aiur.PubSub` topic `"opencode:attach"`.
  """

  use GenServer
  require Logger

  alias Aiur.{AgentEvents, Boot}
  alias Aiur.Opencode.{AgentAttach, Config, HiddenWindow, WorkspaceSetup}

  @warm_topic "opencode:warm"
  @attach_topic "opencode:attach"

  defstruct base_url: nil,
            pending: [],
            inflight: nil,
            priorities: MapSet.new(),
            cancellations: MapSet.new(),
            inflight_started_at: nil,
            seen: MapSet.new()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec attach_topic() :: String.t()
  def attach_topic, do: @attach_topic

  @spec enqueue(String.t()) :: :ok
  def enqueue(identifier) when is_binary(identifier) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:enqueue, identifier})
    else
      :ok
    end
  end

  @doc """
  Mark `identifier` as user-priority. If it has not yet been attached,
  it jumps the queue. If it is currently in flight, the priority flag
  causes the attach completion event to be `:pane_priority_attached`
  (PaneManager promotes to visible). Returns the current state of the
  pane so callers can decide whether to wait.
  """
  @spec request_priority(String.t()) ::
          {:ok, :inflight | :queued | :already_attached | :unknown}
  def request_priority(identifier) when is_binary(identifier) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:request_priority, identifier}, 5_000)
    else
      {:ok, :unknown}
    end
  end

  @doc """
  Mark `identifier` as cancelled. If an attach completes for this
  identifier, do not emit the priority-attached event — the pane lands
  in `:hidden` and stays there. Idempotent.
  """
  @spec cancel(String.t()) :: :ok
  def cancel(identifier) when is_binary(identifier) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:cancel, identifier})
    else
      :ok
    end
  end

  @spec snapshot() :: %{
          base_url: String.t() | nil,
          pending: [String.t()],
          inflight: String.t() | nil,
          priorities: [String.t()],
          cancellations: [String.t()]
        }
  def snapshot do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :snapshot, 200)
    else
      %{base_url: nil, pending: [], inflight: nil, priorities: [], cancellations: []}
    end
  catch
    :exit, _ ->
      %{base_url: nil, pending: [], inflight: nil, priorities: [], cancellations: []}
  end

  # ----- GenServer callbacks -------------------------------------------------

  @impl true
  def init(_opts) do
    if Config.prewarm_disabled?() do
      :ignore
    else
      :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, @warm_topic)
      :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, AgentEvents.running_topic())
      {:ok, %__MODULE__{}}
    end
  end

  @impl true
  def handle_info({:warm_server_ready, base_url}, state) do
    Logger.info(
      "opencode_attach_queue phase=warm_ready elapsed_ms=#{Boot.elapsed_ms()} base_url=#{base_url}"
    )

    new_state = %{state | base_url: base_url}
    new_state = maybe_seed_from_directory(new_state)
    # Force a rematerialize regardless of whether do_enqueue saw new ids
    # — agents that arrived BEFORE warm_server_ready were enqueued with
    # state.base_url = nil and skipped the per-enqueue rematerialize.
    _ = maybe_rematerialize_warm(new_state, new_state.seen)
    {:noreply, maybe_start_next(new_state)}
  end

  def handle_info({:running_changed, summaries}, state) do
    identifiers =
      summaries
      |> Enum.map(& &1.identifier)
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 == ""))

    new_state =
      Enum.reduce(identifiers, state, fn id, acc ->
        do_enqueue(acc, id)
      end)

    {:noreply, maybe_start_next(new_state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Task ref already cleared in handle_info({:attach_done, …}).
    {:noreply, state}
  end

  def handle_info({:attach_done, identifier, result}, state) do
    duration_ms =
      case state.inflight_started_at do
        nil -> 0
        ts -> System.monotonic_time(:millisecond) - ts
      end

    {priority?, priorities} = pop_member(state.priorities, identifier)
    {cancelled?, cancellations} = pop_member(state.cancellations, identifier)

    case result do
      {:ok, _pane} ->
        cond do
          cancelled? ->
            Logger.info(
              "opencode_attach_queue phase=inflight_done_cancelled elapsed_ms=#{Boot.elapsed_ms()} attach_ms=#{duration_ms} identifier=#{identifier}"
            )

            broadcast({:pane_attached, identifier})

          priority? ->
            Logger.info(
              "opencode_attach_queue phase=inflight_done_priority elapsed_ms=#{Boot.elapsed_ms()} attach_ms=#{duration_ms} identifier=#{identifier}"
            )

            broadcast({:pane_priority_attached, identifier})

          true ->
            Logger.info(
              "opencode_attach_queue phase=inflight_done elapsed_ms=#{Boot.elapsed_ms()} attach_ms=#{duration_ms} identifier=#{identifier}"
            )

            broadcast({:pane_attached, identifier})
        end

      {:error, reason} ->
        Logger.warning(
          "opencode_attach_queue phase=inflight_failed elapsed_ms=#{Boot.elapsed_ms()} attach_ms=#{duration_ms} identifier=#{identifier} reason=#{inspect(reason)}"
        )

        broadcast({:pane_attach_failed, identifier, reason})
    end

    new_state = %{
      state
      | inflight: nil,
        inflight_started_at: nil,
        priorities: priorities,
        cancellations: cancellations
    }

    {:noreply, maybe_start_next(new_state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast({:enqueue, identifier}, state) do
    {:noreply, do_enqueue(state, identifier) |> maybe_start_next()}
  end

  def handle_cast({:cancel, identifier}, state) do
    Logger.info(
      "opencode_attach_queue phase=cancel elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier}"
    )

    {:noreply, %{state | cancellations: MapSet.put(state.cancellations, identifier)}}
  end

  @impl true
  def handle_call({:request_priority, identifier}, _from, state) do
    cond do
      identifier_already_attached?(identifier) ->
        Logger.info(
          "opencode_attach_queue phase=priority_already_attached elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier}"
        )

        {:reply, {:ok, :already_attached}, state}

      state.inflight == identifier ->
        Logger.info(
          "opencode_attach_queue phase=priority_jump_inflight elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier}"
        )

        new_state = %{state | priorities: MapSet.put(state.priorities, identifier)}
        {:reply, {:ok, :inflight}, new_state}

      identifier in state.pending ->
        Logger.info(
          "opencode_attach_queue phase=priority_jump_pending elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier}"
        )

        new_pending = [identifier | List.delete(state.pending, identifier)]

        new_state = %{
          state
          | pending: new_pending,
            priorities: MapSet.put(state.priorities, identifier)
        }

        {:reply, {:ok, :queued}, maybe_start_next(new_state)}

      true ->
        # Unknown identifier — auto-enqueue at the front with priority.
        Logger.info(
          "opencode_attach_queue phase=priority_enqueue elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier}"
        )

        new_state =
          state
          |> do_enqueue(identifier, prepend: true)
          |> Map.update!(:priorities, &MapSet.put(&1, identifier))

        {:reply, {:ok, :queued}, maybe_start_next(new_state)}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       base_url: state.base_url,
       pending: state.pending,
       inflight: state.inflight,
       priorities: MapSet.to_list(state.priorities),
       cancellations: MapSet.to_list(state.cancellations)
     }, state}
  end

  # ----- internals -----------------------------------------------------------

  defp do_enqueue(state, identifier, opts \\ []) do
    cond do
      MapSet.member?(state.seen, identifier) and not Keyword.get(opts, :prepend, false) ->
        state

      true ->
        pending =
          if Keyword.get(opts, :prepend, false) do
            [identifier | List.delete(state.pending, identifier)]
          else
            if identifier in state.pending, do: state.pending, else: state.pending ++ [identifier]
          end

        Logger.info(
          "opencode_attach_queue phase=enqueued elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier} prepend=#{Keyword.get(opts, :prepend, false)} pending_count=#{length(pending)}"
        )

        new_seen = MapSet.put(state.seen, identifier)
        _ = maybe_rematerialize_warm(state, new_seen)
        %{state | pending: pending, seen: new_seen}
    end
  end

  # Refresh the warm workspace's opencode.json so its provider models
  # map declares every agent identifier we know about. Prevents
  # opencode's `Model not found: aiur/issue-<X>. Did you mean: issue-
  # _warm?` error in the chat pane (R6 leak + broken chat UX).
  defp maybe_rematerialize_warm(%{base_url: nil}, _seen), do: :ok

  defp maybe_rematerialize_warm(_state, seen) do
    workspace = Config.prewarm_workspace()
    bridge_url = "http://#{Config.bridge_host()}:#{Config.bridge_port()}"
    ids = MapSet.to_list(seen)
    _ = WorkspaceSetup.rematerialize_prewarm(workspace, bridge_url, ids)
    :ok
  end

  defp maybe_seed_from_directory(state) do
    Aiur.AgentDirectory.list_agents()
    |> Enum.map(& &1.identifier)
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(state, &do_enqueue(&2, &1))
  end

  defp maybe_start_next(%{base_url: nil} = state), do: state
  defp maybe_start_next(%{inflight: id} = state) when not is_nil(id), do: state
  defp maybe_start_next(%{pending: []} = state), do: state

  defp maybe_start_next(state) do
    case HiddenWindow.status() do
      :ready ->
        [next | rest] = state.pending
        started_at = System.monotonic_time(:millisecond)

        Logger.info(
          "opencode_attach_queue phase=inflight_start elapsed_ms=#{Boot.elapsed_ms()} identifier=#{next} queue_remaining=#{length(rest)}"
        )

        parent = self()
        base_url = state.base_url

        # Run AgentAttach in a Task so the queue GenServer can keep
        # handling cancel/priority requests during the attach.
        Task.start_link(fn ->
          result =
            try do
              AgentAttach.attach(next, base_url)
            catch
              kind, reason -> {:error, {kind, reason}}
            end

          send(parent, {:attach_done, next, result})
        end)

        %{state | pending: rest, inflight: next, inflight_started_at: started_at}

      _ ->
        # Hidden window not ready yet — try again on next event.
        state
    end
  end

  defp pop_member(%MapSet{} = set, identifier) do
    if MapSet.member?(set, identifier) do
      {true, MapSet.delete(set, identifier)}
    else
      {false, set}
    end
  end

  defp identifier_already_attached?(identifier) do
    case Aiur.Opencode.SessionWriterRegistry.get_pane(identifier) do
      {:ok, %{status: status}} when status in [:hidden, :visible] -> true
      _ -> false
    end
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Aiur.PubSub, @attach_topic, message)
  end
end
