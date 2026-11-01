defmodule Aiur.Executor.TranscriptIngest do
  @moduledoc """
  Captures only the attached Claude transcript, resuming from durable journal checkpoints.

  Tailer callbacks, session boundaries and cursor commits share this mailbox so
  a boundary cannot overtake records already read. The polling tailer runs under
  a dedicated DynamicSupervisor; manager restart reclaims its stopped readers.
  """
  use GenServer
  alias Aiur.Claude.TranscriptTailer
  alias Aiur.Conversation.{Ingest, Ref}
  alias Aiur.Executor.{Session, SessionIngest, TranscriptFormat, TranscriptPath}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  @doc false
  @spec poll(GenServer.server()) :: :ok
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, :infinity)
  @doc false
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status, 500)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(Keyword.get(opts, :pubsub, Aiur.PubSub), SessionIngest.topic())

    state = %{
      capture: nil,
      emit_alert: Keyword.get(opts, :emit_alert, &Aiur.Alerts.emit_system/2),
      error: nil,
      error_binding: nil,
      home: Keyword.get(opts, :home),
      interval: Keyword.get(opts, :interval_ms, 400),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      supervisor: Keyword.get(opts, :supervisor, Aiur.Executor.TranscriptSupervisor)
    }

    for {_, pid, _, _} <- DynamicSupervisor.which_children(state.supervisor), is_pid(pid), do: DynamicSupervisor.terminate_child(state.supervisor, pid)
    reconcile_detach()
    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:poll, from, state) do
    state = step(state)
    send(self(), {:barrier, from})
    {:noreply, state}
  end

  def handle_call(:status, _from, state), do: {:reply, %{transcript_rejection: state.error}, state}

  @impl true
  def handle_info({:barrier, from}, state) do
    GenServer.reply(from, :ok)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    state = step(state)
    if state.interval, do: Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  def handle_info({:end_binding, id, reason}, %{capture: %{binding: %{provider_session_id: id}, closing: false}} = state),
    do: {:noreply, close(state, reason)}

  def handle_info({:end_binding, id, reason}, %{capture: %{binding: %{provider_session_id: id}, closing: true} = capture} = state),
    do: {:noreply, %{state | capture: %{capture | reason: reason}}}

  def handle_info({:end_binding, id, reason}, %{capture: nil} = state) do
    Ingest.end_session(Ref.executor(), id, reason)
    {:noreply, state}
  end

  def handle_info(:checkpoint, %{capture: %{closing: false} = capture} = state),
    do: {:noreply, %{state | capture: checkpoint(capture, false)}}

  def handle_info({:executor_hook, _event}, state), do: {:noreply, step(state)}

  def handle_info({token, {:record, record}}, %{capture: %{token: token} = capture} = state) do
    format = capture.format |> TranscriptFormat.count(record) |> TranscriptFormat.alert(capture.binding, state.emit_alert)
    {:noreply, %{state | capture: %{capture | format: format}}}
  end

  def handle_info({token, {:event, event}}, %{capture: %{token: token} = capture} = state) do
    {:noreply, %{state | capture: %{capture | pending: [event | capture.pending]}}}
  end

  def handle_info({token, {:offset, offset}}, %{capture: %{token: token} = capture} = state) do
    Ingest.append(Ref.executor(), capture.source, Enum.reverse(capture.pending))
    {:noreply, %{state | capture: checkpoint(%{capture | offset: offset, pending: []}, false)}}
  end

  def handle_info({token, {:status, :reset}}, %{capture: %{token: token} = capture} = state) do
    Ingest.end_session(Ref.executor(), capture.binding.provider_session_id, "superseded")
    {:noreply, %{state | capture: %{capture | source: %{capture.source | start_reason: "fork"}, offset: 0}}}
  end

  def handle_info({token, {:status, status}}, %{capture: %{token: token} = capture} = state) do
    gap =
      case {status, capture.gap} do
        {:unreadable, nil} ->
          DateTime.utc_now()

        {:readable, %DateTime{} = from} ->
          Ingest.gap(Ref.executor(), :source_unreadable, from, DateTime.utc_now())
          nil

        _ ->
          capture.gap
      end

    {:noreply, %{state | capture: %{capture | gap: gap}}}
  end

  def handle_info({:finish, token}, %{capture: %{token: token} = capture} = state) do
    checkpoint(capture, true)
    if capture.gap, do: Ingest.gap(Ref.executor(), :source_unreadable, capture.gap, DateTime.utc_now())
    Ingest.end_session(Ref.executor(), capture.binding.provider_session_id, capture.reason)
    {:noreply, start_capture(%{state | capture: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{capture: capture}) when not is_nil(capture) do
    checkpoint(capture, true)
    if Process.alive?(capture.pid), do: DynamicSupervisor.terminate_child(capture.supervisor, capture.pid)
  end

  def terminate(_reason, _state), do: :ok

  defp step(%{capture: nil} = state), do: state |> start_capture() |> read_capture()
  defp step(%{capture: %{closing: true}} = state), do: state

  defp step(state) do
    case Session.current() do
      {:ok, binding} ->
        if identity(binding) == identity(state.capture.binding) and binding.state == "attached" do
          read_capture(state)
        else
          close(state, retarget_reason(binding))
        end

      :none ->
        close(state, "detached")
    end
  end

  defp retarget_reason(%{state: "detached", end_reason: reason}), do: reason || "detached"
  defp retarget_reason(_binding), do: "superseded"

  defp close(state, reason) do
    if Process.alive?(state.capture.pid) do
      validate_read(state)
      DynamicSupervisor.terminate_child(state.supervisor, state.capture.pid)
    end

    send(self(), {:finish, state.capture.token})
    %{state | capture: Map.merge(state.capture, %{closing: true, reason: reason})}
  end

  defp read_capture(%{capture: nil} = state), do: state

  defp read_capture(state) do
    if Process.alive?(state.capture.pid) do
      validate_read(state)
      send(self(), :checkpoint)
      state
    else
      start_capture(%{state | capture: nil})
    end
  end

  defp validate_read(state) do
    binding = state.capture.binding
    opts = path_options(state)

    case TranscriptPath.validate(binding.transcript_path, "claude", binding.provider_session_id, opts) do
      {:ok, _} -> TranscriptTailer.poll(state.capture.pid, :infinity)
      {:error, _} -> send(self(), {state.capture.token, {:status, :unreadable}})
    end
  end

  defp path_options(state), do: if(state.home, do: [home: state.home], else: [])

  defp start_capture(state) do
    case Session.current() do
      {:ok, %{harness: "claude", state: "attached", transcript_path: path} = binding} when is_binary(path) ->
        case TranscriptPath.validate(path, "claude", binding.provider_session_id, path_options(state)) do
          {:ok, ^path} ->
            launch_ready(state, binding)

          {:error, reason} ->
            reject_path(state, binding, reason)
        end

      _ ->
        %{state | error: nil, error_binding: nil}
    end
  end

  defp reject_path(state, binding, reason) do
    if state.error != reason or state.error_binding != identity(binding) do
      now = DateTime.utc_now()
      Ingest.gap(Ref.executor(), :source_unreadable, now, now)
    end

    %{state | error: reason, error_binding: identity(binding)}
  end

  defp launch_ready(state, %{clear_rebind_until: _}), do: state
  defp launch_ready(state, binding), do: launch(state, binding)

  defp launch(state, binding) do
    {:ok, writer} = Ingest.writer(Ref.executor())
    owner = self()
    token = make_ref()
    hash = :crypto.hash(:sha256, binding.transcript_path) |> Base.encode16(case: :lower)
    offset = if binding.locator_hash == hash, do: binding.transcript_offset, else: 0

    opts = [
      path: binding.transcript_path,
      from: {:offset, offset},
      interval_ms: nil,
      on_record: fn record -> send(owner, {token, {:record, record}}) end,
      on_message: fn event -> send(owner, {token, {:event, event}}) end,
      on_offset: fn cursor -> send(owner, {token, {:offset, cursor}}) end,
      on_status: fn status -> send(owner, {token, {:status, status}}) end
    ]

    {:ok, pid} = DynamicSupervisor.start_child(state.supervisor, %{id: TranscriptTailer, start: {TranscriptTailer, :start_link, [opts]}, restart: :temporary})

    source = %{
      harness: "claude",
      role: :executor,
      provider_session_id: binding.provider_session_id,
      aiur_attempt_id: nil,
      transcript_source: %{kind: :provider_file, locator_hash: hash},
      start_reason: binding.start_reason
    }

    capture = %{
      pid: pid,
      token: token,
      binding: binding,
      source: source,
      offset: offset,
      written_at: nil,
      gap: nil,
      pending: [],
      format: Map.get(binding, :transcript_format) || TranscriptFormat.new(),
      closing: false,
      reason: nil,
      supervisor: state.supervisor,
      clock: state.clock,
      writer: writer
    }

    %{state | capture: capture, error: nil, error_binding: nil}
  end

  defp reconcile_detach do
    case Session.current() do
      {:ok, %{harness: "claude", state: "detached", provider_session_id: id, end_reason: reason}} when is_binary(id) ->
        Ingest.end_session(Ref.executor(), id, reason || "detached")

      _ ->
        :ok
    end
  end

  defp identity(binding), do: Map.take(binding, [:binding_id, :generation, :provider_session_id, :transcript_path])

  defp checkpoint(capture, force?) do
    now = capture.clock.()

    if force? or is_nil(capture.written_at) or now - capture.written_at >= 2000 do
      with :ok <- GenServer.call(capture.writer, :flush, :infinity),
           {:ok, binding} <- Session.current(),
           true <- identity(binding) == identity(capture.binding),
           {:ok, _} <- Session.record_checkpoint(capture.binding, capture.offset, capture.format) do
        %{capture | written_at: now}
      else
        _ -> capture
      end
    else
      capture
    end
  end
end
