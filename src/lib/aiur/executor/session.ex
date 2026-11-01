defmodule Aiur.Executor.Session do
  @moduledoc """
  Durable, opt-in binding of one external Executor session to this instance.

  `current/0` is daemon-internal; transport callers must use `public/1`.
  Journal sessions open on the first transcript append; `start_reason` is
  carried for that producer. Claude clear/compact rebinding is limited to the
  attached Claude harness and rejects a supplied pid that differs from the
  original process. A clear rebind requires a matching SessionEnd hook and is
  available for 30 seconds; if that hook is lost, the binding recovers after
  its normal session TTL.
  """
  use GenServer
  alias Aiur.Conversation.{Ingest, Ref}
  alias Aiur.Executor.SessionRecord
  alias Aiur.JsonStore

  @type binding :: map()
  @type result :: {:ok, binding()} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  @spec attach(map()) :: result()
  def attach(opts), do: GenServer.call(__MODULE__, {:attach, opts})
  @spec current() :: {:ok, binding()} | :none
  def current, do: GenServer.call(__MODULE__, :current)
  @spec bind_provider_session(String.t(), map()) :: result()
  def bind_provider_session(id, hook), do: GenServer.call(__MODULE__, {:bind, id, hook, false})
  @spec rebind_on_session_start(String.t(), map()) :: result()
  def rebind_on_session_start(id, hook), do: GenServer.call(__MODULE__, {:bind, id, hook, true})
  @spec touch(String.t(), DateTime.t()) :: result()
  def touch(id, at), do: GenServer.call(__MODULE__, {:touch, id, at})
  @spec prepare_clear_rebind(String.t(), map()) :: result()
  def prepare_clear_rebind(id, hook), do: GenServer.call(__MODULE__, {:prepare_clear_rebind, id, hook})
  @spec detach(String.t(), atom() | String.t()) :: result()
  def detach(id, reason), do: GenServer.call(__MODULE__, {:detach, id, reason})
  @spec record_offset(String.t() | binding(), non_neg_integer()) :: result()
  def record_offset(%{binding_id: id} = binding, offset), do: GenServer.call(__MODULE__, {:offset, id, offset, cursor_identity(binding)})
  def record_offset(id, offset), do: GenServer.call(__MODULE__, {:offset, id, offset, nil})
  @spec record_checkpoint(binding(), non_neg_integer(), map()) :: result()
  def record_checkpoint(binding, offset, format), do: GenServer.call(__MODULE__, {:checkpoint, binding, offset, format})
  @spec public(binding()) :: map()
  def public(binding), do: Map.drop(binding, [:transcript_path, :cwd, :pid])
  @spec rejected_counts() :: map()
  def rejected_counts, do: GenServer.call(__MODULE__, :rejected_counts)

  @impl true
  def init(opts) do
    key = Keyword.get(opts, :instance_key, System.get_env("AIUR_INSTANCE_KEY"))
    path = if is_binary(key) and key != "", do: SessionRecord.path(key)
    binding = if path, do: SessionRecord.load(path)
    {:ok, %{path: path, binding: binding, clock: Keyword.get(opts, :clock, &DateTime.utc_now/0), written_at: nil, timer: nil, rejected: %{}}}
  end

  @impl true
  def handle_call(:current, _from, state), do: {:reply, projection(state), state}
  def handle_call(:rejected_counts, _from, state), do: {:reply, state.rejected, state}

  def handle_call({:attach, opts}, _from, state) do
    cond do
      is_nil(state.path) ->
        reject(state, :missing_instance_key)

      not is_map(opts) or Map.get(opts, :harness) not in ["claude", "codex"] ->
        reject(state, :invalid_harness)

      not valid_consumer?(opts) ->
        reject(state, :invalid_consumer_id)

      live?(state.binding, state.clock.()) and Map.get(opts, :takeover?, false) != true ->
        {:reply, {:error, {:already_attached, state |> projection() |> elem(1) |> public()}}, state}

      true ->
        end_binding(state.binding, if(live?(state.binding, state.clock.()), do: "superseded", else: "detached"))
        reply_saved(%{state | binding: SessionRecord.new(opts, state.binding, state.clock.())})
    end
  end

  def handle_call({:bind, id, hook, rebind?}, _from, state) do
    with :ok <- attached(state.binding, id),
         :ok <- valid_hook(hook),
         :ok <- accept_session(state.binding, hook, rebind?, state.clock.()) do
      bind(state, hook, rebind?, state.clock.())
    else
      {:error, reason} -> reject(state, reason)
    end
  end

  def handle_call({:touch, id, %DateTime{} = at}, _from, state) do
    case attached(state.binding, id) do
      :ok ->
        reply_touched(%{state | binding: Map.put(state.binding, :last_hook_at, DateTime.to_iso8601(at))})

      {:error, reason} ->
        reject(state, reason)
    end
  end

  def handle_call({:detach, id, reason}, _from, state) when is_atom(reason) or is_binary(reason) do
    case attached(state.binding, id) do
      :ok ->
        end_binding(state.binding, reason)
        binding = Map.merge(state.binding, %{state: "detached", end_reason: to_string(reason), detached_at: DateTime.to_iso8601(state.clock.()), takeover_armed: false})
        reply_saved(%{state | binding: binding})

      {:error, reason} ->
        reject(state, reason)
    end
  end

  def handle_call({:prepare_clear_rebind, id, hook}, _from, state) do
    with :ok <- attached(state.binding, id),
         :ok <- valid_hook(hook),
         true <-
           hook.event == "SessionEnd" and hook.reason == "clear" and hook.harness == "claude" and hook.session_id == state.binding.provider_session_id and is_binary(state.binding.pid) and
             hook.pid == state.binding.pid do
      end_binding(state.binding, "clear")
      binding = Map.merge(state.binding, %{clear_rebind_pid: hook.pid, clear_rebind_until: DateTime.to_iso8601(DateTime.add(state.clock.(), 30, :second)), takeover_armed: false})
      reply_saved(%{state | binding: binding})
    else
      false -> reject(state, :foreign_session)
      {:error, reason} -> reject(state, reason)
    end
  end

  def handle_call({:offset, id, offset, expected}, _from, state) when is_integer(offset) and offset >= 0 do
    case offset_binding(state.binding, id, expected) do
      :ok ->
        reply_saved(%{state | binding: Map.put(state.binding, :transcript_offset, offset)})

      {:error, reason} ->
        reject(state, reason)
    end
  end

  def handle_call({:checkpoint, binding, offset, format}, _from, state) when is_integer(offset) and offset >= 0 do
    case offset_binding(state.binding, binding.binding_id, cursor_identity(binding)) do
      :ok -> reply_saved(%{state | binding: Map.merge(state.binding, %{transcript_offset: offset, transcript_format: format})})
      {:error, reason} -> reject(state, reason)
    end
  end

  def handle_call(_request, _from, state), do: reject(state, :invalid_request)

  @impl true
  def handle_info({:persist_touch, token}, %{timer: {_timer, token}} = state), do: {:noreply, save(%{state | timer: nil})}
  def handle_info({:persist_touch, _token}, state), do: {:noreply, state}

  defp bind(state, hook, rebind?, now) do
    binding = state.binding
    changed? = binding.provider_session_id != hook.session_id
    stale? = not live?(binding, now)
    reason = if rebind?, do: hook.source, else: "start"
    clear_already_ended? = clear_rebind_live?(binding, now)
    if changed? and not clear_already_ended?, do: end_binding(binding, if(stale?, do: "detached", else: reason))

    updated = provider_fields(binding, hook, now)
    updated = if updated.transcript_path != binding.transcript_path, do: Map.put(updated, :transcript_offset, 0), else: updated
    updated = if changed?, do: Map.merge(updated, %{start_reason: reason, transcript_offset: 0}), else: updated
    updated = if changed?, do: Map.drop(updated, [:clear_rebind_pid, :clear_rebind_until]), else: updated

    if Map.drop(updated, [:last_hook_at]) == Map.drop(binding, [:last_hook_at]), do: reply_touched(%{state | binding: updated}), else: reply_saved(%{state | binding: updated})
  end

  defp provider_fields(binding, hook, now) do
    path = Map.get(hook, :transcript_path) || if(binding.provider_session_id == hook.session_id, do: binding.transcript_path)

    Map.merge(binding, %{
      state: "attached",
      provider_session_id: hook.session_id,
      transcript_path: path,
      locator_hash: locator_hash(path),
      cwd: Map.get(hook, :cwd),
      pid: if(binding.provider_session_id != hook.session_id or not live?(binding, now), do: Map.get(hook, :pid), else: binding.pid || Map.get(hook, :pid)),
      last_hook_at: DateTime.to_iso8601(now),
      takeover_armed: false
    })
  end

  defp cursor_identity(binding), do: Map.take(binding, [:binding_id, :generation, :provider_session_id, :transcript_path, :locator_hash])

  defp offset_binding(binding, id, expected) do
    with :ok <- attached(binding, id) do
      if is_nil(expected) or cursor_identity(binding) == expected, do: :ok, else: {:error, :binding_changed}
    end
  end

  defp valid_consumer?(opts), do: is_nil(Map.get(opts, :consumer_id)) or is_binary(Map.get(opts, :consumer_id))

  defp accept_session(binding, hook, rebind?, now) do
    cond do
      rebind? -> validate_rebind(binding, hook, now)
      binding.takeover_armed or not live?(binding, now) -> :ok
      binding.provider_session_id in [nil, hook.session_id] -> same_process(binding, hook)
      true -> {:error, :foreign_session}
    end
  end

  defp same_process(binding, hook) do
    if binding.pid && Map.get(hook, :pid) not in [nil, binding.pid], do: {:error, :foreign_session}, else: :ok
  end

  defp validate_rebind(binding, %{source: "clear"} = hook, now) do
    pending? = Map.get(binding, :clear_rebind_pid) == hook.pid and is_binary(hook.pid) and clear_rebind_live?(binding, now)
    if binding.harness == "claude" and binding.state == "attached" and pending? and hook.session_id != binding.provider_session_id, do: :ok, else: {:error, :foreign_session}
  end

  defp validate_rebind(binding, hook, _now) do
    if binding.harness == "claude" and binding.state == "attached" and
         hook.session_id == binding.provider_session_id and
         Map.get(hook, :source) in ["compact", "resume", "fork"] and
         Map.get(hook, :pid) in [nil, binding.pid], do: :ok, else: {:error, :foreign_session}
  end

  defp clear_rebind_live?(%{clear_rebind_until: until}, now) when is_binary(until) do
    case DateTime.from_iso8601(until) do
      {:ok, at, _} -> DateTime.compare(now, at) != :gt
      _ -> false
    end
  end

  defp clear_rebind_live?(_, _), do: false

  defp valid_hook(%{session_id: id} = hook) when is_binary(id) and id != "" do
    if Enum.all?([:transcript_path, :cwd, :pid], &(is_nil(Map.get(hook, &1)) or is_binary(Map.get(hook, &1)))), do: :ok, else: {:error, :invalid_hook}
  end

  defp valid_hook(_hook), do: {:error, :invalid_hook}
  defp attached(%{binding_id: id, state: state}, id) when state in ["awaiting_first_hook", "attached"], do: :ok
  defp attached(_binding, _id), do: {:error, :not_attached}
  defp live?(nil, _now), do: false
  defp live?(%{state: "detached"}, _now), do: false

  defp live?(binding, now) do
    {:ok, at, _offset} = DateTime.from_iso8601(binding.last_hook_at || binding.attached_at)
    DateTime.diff(now, at, :millisecond) <= Application.get_env(:aiur, :executor_session_ttl_ms, 600_000)
  end

  defp projection(%{binding: nil}), do: :none
  defp projection(state), do: {:ok, Map.put(state.binding, :live?, live?(state.binding, state.clock.()))}

  defp end_binding(%{provider_session_id: id, state: state} = binding, reason) when is_binary(id) and state != "detached" do
    case {binding.harness, Process.whereis(Aiur.Executor.TranscriptIngest)} do
      {"claude", pid} when is_pid(pid) -> send(pid, {:end_binding, id, reason})
      _ -> Ingest.end_session(Ref.executor(), id, reason)
    end
  end

  defp end_binding(_binding, _reason), do: :ok
  defp locator_hash(nil), do: nil
  defp locator_hash(path), do: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)
  defp reject(state, reason), do: {:reply, {:error, reason}, %{state | rejected: Map.update(state.rejected, reason, 1, &(&1 + 1))}}

  defp reply_saved(state) do
    state = save(state)
    {:reply, projection(state), state}
  end

  defp reply_touched(state) do
    elapsed = if state.written_at, do: System.monotonic_time(:millisecond) - state.written_at, else: 1000

    cond do
      elapsed >= 1000 ->
        reply_saved(state)

      state.timer ->
        {:reply, projection(state), state}

      true ->
        token = make_ref()
        timer = Process.send_after(self(), {:persist_touch, token}, 1000 - elapsed)
        {:reply, projection(state), %{state | timer: {timer, token}}}
    end
  end

  defp save(state) do
    if state.timer, do: Process.cancel_timer(elem(state.timer, 0))
    JsonStore.write!(state.path, state.binding, mode: 0o600)
    %{state | written_at: System.monotonic_time(:millisecond), timer: nil}
  end
end
