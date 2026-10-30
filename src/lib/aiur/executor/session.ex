defmodule Aiur.Executor.Session do
  @moduledoc """
  Durable, opt-in binding of one external Executor session to this instance.

  `current/0` is daemon-internal; transport callers must use `public/1`.
  Journal sessions open on the first transcript append; `start_reason` is
  carried for that producer. Rebinding requires the same nonempty `pid`
  supplied by the first authenticated hook.
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
  @spec detach(String.t(), atom() | String.t()) :: result()
  def detach(id, reason), do: GenServer.call(__MODULE__, {:detach, id, reason})
  @spec record_offset(String.t(), non_neg_integer()) :: result()
  def record_offset(id, offset), do: GenServer.call(__MODULE__, {:offset, id, offset})
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
      bind(state, hook, rebind?)
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

  def handle_call({:offset, id, offset}, _from, state) when is_integer(offset) and offset >= 0 do
    case attached(state.binding, id) do
      :ok ->
        reply_saved(%{state | binding: Map.put(state.binding, :transcript_offset, offset)})

      {:error, reason} ->
        reject(state, reason)
    end
  end

  def handle_call(_request, _from, state), do: reject(state, :invalid_request)

  @impl true
  def handle_info({:persist_touch, token}, %{timer: {_timer, token}} = state), do: {:noreply, save(%{state | timer: nil})}
  def handle_info({:persist_touch, _token}, state), do: {:noreply, state}

  defp bind(state, hook, rebind?) do
    binding = state.binding
    changed? = binding.provider_session_id != hook.session_id
    stale? = not live?(binding, state.clock.())
    reason = if rebind?, do: hook.source, else: "start"
    if changed?, do: end_binding(binding, if(stale?, do: "detached", else: reason))

    updated = provider_fields(binding, hook, state.clock.())
    updated = if changed?, do: Map.merge(updated, %{start_reason: reason, transcript_offset: 0}), else: updated

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

  defp valid_consumer?(opts), do: is_nil(Map.get(opts, :consumer_id)) or is_binary(Map.get(opts, :consumer_id))

  defp accept_session(binding, hook, rebind?, now) do
    cond do
      rebind? -> validate_rebind(binding, hook)
      binding.takeover_armed or not live?(binding, now) -> :ok
      binding.provider_session_id in [nil, hook.session_id] -> same_process(binding, hook)
      true -> {:error, :foreign_session}
    end
  end

  defp same_process(binding, hook) do
    if binding.pid && Map.get(hook, :pid) not in [nil, binding.pid], do: {:error, :foreign_session}, else: :ok
  end

  defp validate_rebind(binding, hook) do
    if binding.harness == "claude" and binding.state == "attached" and
         Map.get(hook, :source) in ["clear", "compact", "resume", "fork"] and
         is_binary(binding.pid) and binding.pid != "" and Map.get(hook, :pid) == binding.pid, do: :ok, else: {:error, :foreign_session}
  end

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

  defp end_binding(%{provider_session_id: id, state: state}, reason) when is_binary(id) and state != "detached",
    do: Ingest.end_session(Ref.executor(), id, reason)

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
