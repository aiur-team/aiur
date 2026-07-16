defmodule Aiur.Workspace.Ownership.Guardian do
  @moduledoc false

  alias Aiur.Claude.RemoteControl
  alias Aiur.Workspace.Ownership
  alias Aiur.Workspace.Ownership.Store

  @reap_retry_ms 1_000

  @spec start(pid(), String.t(), pos_integer(), pid() | atom(), keyword()) :: pid()
  def start(owner, ticket, generation, registry, opts) do
    spawn(fn -> init(owner, ticket, generation, registry, opts) end)
  end

  @spec restore(map(), pid() | atom(), keyword()) :: {:ok, Ownership.lease()} | {:error, term()}
  def restore(receipt, registry, opts) when is_map(receipt) and is_list(opts) do
    caller = self()
    guardian = spawn(fn -> init_restored(caller, receipt, registry, opts) end)

    receive do
      {:workspace_guardian_restored, ^guardian, result} -> result
    after
      5_000 ->
        Process.exit(guardian, :kill)
        {:error, :workspace_reconciliation_timeout}
    end
  end

  defp init(owner, ticket, generation, registry, opts) do
    lease = %{
      ticket: ticket,
      generation: generation,
      owner_id: "workspace:#{generation}",
      phase: :provisioning,
      guardian: self()
    }

    case Registry.register(registry, ticket, lease) do
      {:ok, _value} ->
        state =
          runtime_state(
            registry,
            lease,
            Process.monitor(owner),
            false,
            %{provider_expected?: false, provider: nil, provider_cleanup: :not_started},
            opts
          )

        case persist_state(state) do
          :ok ->
            emit_telemetry(state, :start, :claimed)
            send(owner, {:workspace_guardian_claimed, self(), {:ok, lease}})
            loop(state)

          {:error, reason} ->
            Registry.unregister(registry, ticket)
            send(owner, {:workspace_guardian_claimed, self(), {:error, {:workspace_ownership_unavailable, reason}}})
        end

      {:error, {:already_registered, _pid}} ->
        result = {:error, {:workspace_owned, Ownership.current(ticket, registry)}}
        send(owner, {:workspace_guardian_claimed, self(), result})
    end
  end

  defp init_restored(caller, receipt, registry, opts) do
    lease = %{
      ticket: Map.fetch!(receipt, :ticket),
      generation: Map.fetch!(receipt, :generation),
      owner_id: Map.fetch!(receipt, :owner_id),
      phase: :reaping,
      guardian: self()
    }

    case Registry.register(registry, lease.ticket, lease) do
      {:ok, _value} ->
        state = runtime_state(registry, lease, nil, true, receipt, opts)
        send(caller, {:workspace_guardian_restored, self(), {:ok, lease}})
        maybe_release_or_reap(state)

      {:error, {:already_registered, _pid}} ->
        send(caller, {:workspace_guardian_restored, self(), {:error, {:workspace_owned, Ownership.current(lease.ticket, registry)}}})
    end
  rescue
    error -> send(caller, {:workspace_guardian_restored, self(), {:error, {:invalid_workspace_receipt, error}}})
  end

  defp runtime_state(registry, lease, owner_ref, owner_dead?, receipt, opts) do
    %{
      owner_ref: owner_ref,
      owner_dead?: owner_dead?,
      registry: registry,
      store: Keyword.get(opts, :store, Store),
      lease: lease,
      provider_expected?: Map.get(receipt, :provider_expected?, false),
      provider: Map.get(receipt, :provider),
      provider_cleanup: Map.get(receipt, :provider_cleanup, :unresolved),
      waiters: MapSet.new(),
      release_waiters: [],
      reap_fun: Keyword.get(opts, :reap_fun, &RemoteControl.reap_process_group/2),
      group_alive_fun: Keyword.get(opts, :group_alive_fun, &RemoteControl.process_group_alive?/1),
      root_reap_fun: Keyword.get(opts, :root_reap_fun, &RemoteControl.reap_process_tree/2),
      root_alive_fun: Keyword.get(opts, :root_alive_fun, &RemoteControl.process_alive?/1),
      process_reap_fun: Keyword.get(opts, :process_reap_fun, &RemoteControl.reap_process/2),
      process_alive_fun: Keyword.get(opts, :process_alive_fun, &RemoteControl.process_alive?/1),
      process_identity_fun: Keyword.get(opts, :process_identity_fun, &RemoteControl.process_identity/1),
      telemetry_fun: Keyword.get(opts, :telemetry_fun, fn _lease, _boundary, _outcome -> :ok end),
      reaping?: false,
      release_requested?: false
    }
  end

  defp loop(state) do
    receive do
      {:workspace_guardian_call, from, ref, {:activate, generation}} ->
        {reply, next} = activate(state, generation)
        reply(from, ref, reply)
        loop(next)

      {:workspace_guardian_call, from, ref, {:expect_provider, generation}} ->
        {reply_value, next} = expect_provider(state, generation)
        reply(from, ref, reply_value)
        loop(next)

      {:workspace_guardian_call, from, ref, {:cancel_provider_expectation, generation}} ->
        {reply_value, next} = cancel_provider_expectation(state, generation)
        reply(from, ref, reply_value)
        loop(next)

      {:workspace_guardian_call, from, ref, {:track_provider, generation, provider}} ->
        {reply_value, next} = track_provider(state, generation, provider)
        reply(from, ref, reply_value)

        if reply_value == :ok,
          do: continue_after_provider_update(next),
          else: loop(next)

      {:workspace_guardian_call, from, ref, {:mark_provider_cleanup_unknown, generation}} ->
        {reply_value, next} = mark_provider_cleanup_unknown(state, generation)
        reply(from, ref, reply_value)
        loop(next)

      {:workspace_guardian_call, from, ref, {:mark_provider_cleanup_succeeded, generation}} ->
        {reply_value, next} = mark_provider_cleanup_succeeded(state, generation)
        reply(from, ref, reply_value)
        loop(next)

      {:workspace_guardian_call, from, ref, {:track_process_group, generation, process_group_id}} ->
        {reply_value, next} = track_provider(state, generation, %{process_group_id: process_group_id})
        reply(from, ref, reply_value)

        if reply_value == :ok,
          do: continue_after_provider_update(next),
          else: loop(next)

      {:workspace_guardian_call, from, ref, {:release, generation}} ->
        if generation == state.lease.generation,
          do: maybe_release_or_reap(request_release(state, {from, ref, :release})),
          else:
            (
              reply(from, ref, :ok)
              loop(state)
            )

      {:workspace_guardian_call, from, ref, {:release_and_wait, generation}} ->
        if generation == state.lease.generation do
          maybe_release_or_reap(request_release(state, {from, ref, :await}))
        else
          reply(from, ref, {:error, :workspace_ownership_lost})
          loop(state)
        end

      {:workspace_guardian_call, from, ref, {:wait_for_release, recipient}} when is_pid(recipient) ->
        # Store the waiter before acknowledging it. The acknowledgement carries
        # this exact generation so a subscriber can reject an ABA replacement.
        next = %{state | waiters: MapSet.put(state.waiters, recipient)}
        reply(from, ref, {:waiting, state.lease.generation})
        loop(next)

      {:DOWN, owner_ref, :process, _owner, _reason} when owner_ref == state.owner_ref ->
        maybe_release_or_reap(%{state | owner_dead?: true})

      {:workspace_guardian_reaped, kind, identifier} ->
        continue_after_reap(state, kind, identifier)

      :workspace_guardian_retry_reap ->
        maybe_release_or_reap(%{state | reaping?: false})

      _other ->
        loop(state)
    end
  end

  defp continue_after_provider_update(%{owner_dead?: true} = state), do: maybe_release_or_reap(state)
  defp continue_after_provider_update(state), do: loop(state)

  defp activate(state, generation) when generation == state.lease.generation do
    case Registry.update_value(state.registry, state.lease.ticket, &Map.put(&1, :phase, :active)) do
      {%{generation: ^generation} = lease, _previous} ->
        next = %{state | lease: lease}

        case persist_state(next) do
          :ok ->
            emit_telemetry(next, :point, :active)
            {{:ok, lease}, next}

          {:error, _reason} ->
            {{:error, :workspace_ownership_lost}, next}
        end

      _ ->
        {{:error, :workspace_ownership_lost}, state}
    end
  end

  defp activate(state, _generation), do: {{:error, :workspace_ownership_lost}, state}

  defp expect_provider(%{lease: %{generation: generation, phase: phase}} = state, generation)
       when phase in [:provisioning, :active] do
    persist_update(state, %{state | provider_expected?: true, provider_cleanup: :unresolved})
  end

  defp expect_provider(state, _generation), do: {{:error, :workspace_ownership_lost}, state}

  defp cancel_provider_expectation(%{lease: %{generation: generation}, provider: nil} = state, generation),
    do: persist_update(state, %{state | provider_expected?: false, provider_cleanup: :not_started})

  defp cancel_provider_expectation(state, _generation), do: {{:error, :workspace_ownership_lost}, state}

  defp track_provider(%{lease: %{generation: generation, phase: phase}} = state, generation, provider)
       when phase in [:provisioning, :active] and is_map(provider) do
    provider =
      state.provider
      |> Kernel.||(%{})
      |> merge_provider(provider)
      |> capture_provider_identities(state.process_identity_fun)

    if valid_provider?(provider) do
      persist_update(state, %{state | provider_expected?: true, provider: provider})
    else
      {{:error, :workspace_ownership_lost}, state}
    end
  end

  defp track_provider(state, _generation, _provider), do: {{:error, :workspace_ownership_lost}, state}

  defp mark_provider_cleanup_unknown(%{lease: %{generation: generation, phase: phase}} = state, generation)
       when phase in [:provisioning, :active] do
    next =
      if state.provider_cleanup == :succeeded,
        do: state,
        else: %{state | provider_cleanup: :failed}

    persist_update(state, next)
  end

  defp mark_provider_cleanup_unknown(state, _generation), do: {{:error, :workspace_ownership_lost}, state}

  defp mark_provider_cleanup_succeeded(%{lease: %{generation: generation, phase: phase}} = state, generation)
       when phase in [:provisioning, :active],
       do: persist_update(state, %{state | provider_cleanup: :succeeded})

  defp mark_provider_cleanup_succeeded(state, _generation), do: {{:error, :workspace_ownership_lost}, state}

  defp persist_update(_previous, next) do
    case persist_state(next) do
      :ok -> {:ok, next}
      {:error, _reason} -> {{:error, :workspace_ownership_lost}, next}
    end
  end

  defp valid_provider?(%{remote: true}), do: true
  defp valid_provider?(%{process_group_id: process_group_id}) when is_integer(process_group_id) and process_group_id > 0, do: true
  defp valid_provider?(%{root_pid: root_pid}) when is_integer(root_pid) and root_pid > 0, do: true

  defp valid_provider?(%{descendant_pids: pids}) when is_list(pids),
    do: Enum.any?(pids, &(is_integer(&1) and &1 > 0))

  defp valid_provider?(_provider), do: false

  # A provider can be reported more than once while its session is starting.
  # Each process-tree result is only a point-in-time observation, so narrowing
  # a later observation must not make an already observed descendant disposable.
  defp merge_provider(previous, incoming) do
    merged = Map.merge(previous, Map.take(incoming, [:process_group_id, :root_pid, :remote, :descendant_pids]))

    if Map.has_key?(previous, :descendant_pids) or Map.has_key?(incoming, :descendant_pids) do
      descendants =
        [previous, incoming]
        |> Enum.flat_map(&observed_descendant_pids/1)
        |> Enum.uniq()

      Map.put(merged, :descendant_pids, descendants)
    else
      merged
    end
  end

  defp observed_descendant_pids(provider) do
    case Map.get(provider, :descendant_pids) do
      pids when is_list(pids) -> Enum.filter(pids, &(is_integer(&1) and &1 > 0))
      _ -> []
    end
  end

  # A live provider with no verified containment is deliberately fail-closed.
  # The owner may have died between OS spawn and metadata inspection; releasing
  # here would allow a retry to replace the provider's cwd underneath it.
  defp maybe_release_or_reap(%{provider_cleanup: :succeeded} = state),
    do: release_guardian(state)

  defp maybe_release_or_reap(%{provider: nil, provider_expected?: true} = state) do
    loop(update_phase(state, :reaping))
  end

  defp maybe_release_or_reap(%{provider: nil} = state), do: release_guardian(state)

  defp maybe_release_or_reap(%{reaping?: true} = state), do: loop(state)

  defp maybe_release_or_reap(%{provider: %{remote: true}, release_requested?: true} = state),
    do: release_guardian(state)

  # A remote provider has no local PID identity or reaper. Time passing is not
  # evidence that its remote cwd is unused, so an abrupt local-owner death
  # retains the generation rather than allowing a retry to remove that cwd.
  defp maybe_release_or_reap(%{provider: %{remote: true}} = state),
    do: loop(update_phase(state, :reaping))

  defp maybe_release_or_reap(%{provider: %{process_group_id: group}} = state)
       when is_integer(group) and group > 0 do
    case provider_identity_state(state, :group, group, state.group_alive_fun) do
      :live -> start_reap(state, :group, group)
      status when status in [:gone, :reused] -> maybe_reap_descendants(state)
      :unknown -> maybe_reap_group_descendants_or_wait(state, group)
    end
  end

  # A no-group snapshot cannot prove that an abruptly dead provider has no
  # reparented or late children. Reap identities we did observe, but retain the
  # generation once that snapshot is exhausted rather than reprovisioning its cwd.
  defp maybe_release_or_reap(
         %{
           owner_dead?: owner_dead?,
           provider_cleanup: provider_cleanup,
           provider: %{root_pid: root_pid, descendant_pids: process_ids}
         } = state
       )
       when (owner_dead? or provider_cleanup == :failed) and is_integer(root_pid) and root_pid > 0 and
              is_list(process_ids),
       do: maybe_reap_no_group_snapshot_or_retain(state)

  defp maybe_release_or_reap(%{provider: %{root_pid: root_pid, descendant_pids: process_ids}} = state)
       when is_integer(root_pid) and root_pid > 0 and is_list(process_ids),
       do: maybe_reap_descendants(state)

  defp maybe_release_or_reap(%{provider: %{root_pid: root_pid}} = state)
       when is_integer(root_pid) and root_pid > 0,
       do: maybe_reap_root(state, root_pid)

  defp maybe_release_or_reap(state), do: loop(update_phase(state, :reaping))

  defp maybe_reap_descendants(state) do
    case live_provider_processes(state) do
      %{live: [], unverified?: false} -> release_guardian(state)
      %{live: [], unverified?: true} -> schedule_reap_retry(state)
      %{live: live_process_ids} -> start_reap(state, :processes, live_process_ids)
    end
  end

  defp maybe_reap_no_group_snapshot_or_retain(state) do
    case live_provider_processes(state) do
      %{live: live_process_ids} when live_process_ids != [] -> start_reap(state, :processes, live_process_ids)
      _ -> loop(update_phase(state, :reaping))
    end
  end

  # A group can outlive its leader or its one-time descendant snapshot. The
  # group identifier is unsafe to signal unless the leader identity still
  # matches, so release only after the group probe and recorded children agree.
  defp maybe_reap_group_descendants_or_wait(state, group) do
    case live_provider_processes(state) do
      %{live: [], unverified?: false} ->
        if safely_alive?(state.group_alive_fun, group), do: schedule_reap_retry(state), else: release_guardian(state)

      %{live: [], unverified?: true} ->
        schedule_reap_retry(state)

      %{live: live_process_ids} ->
        start_reap(state, :processes, live_process_ids)
    end
  end

  defp maybe_reap_root(state, root_pid) do
    case provider_identity_state(state, :root, root_pid, state.root_alive_fun) do
      :live -> start_reap(state, :root, root_pid)
      status when status in [:gone, :reused] -> release_guardian(state)
      :unknown -> schedule_reap_retry(state)
    end
  end

  defp start_reap(state, kind, identifier) do
    state = update_phase(state, :reaping)
    guardian = self()
    reap_fun = reap_fun_for(state, kind)
    expected_identity = reaping_identity(state, kind, identifier)

    spawn(fn ->
      reap_identifier(reap_fun, identifier, expected_identity)
      send(guardian, {:workspace_guardian_reaped, kind, identifier})
    end)

    loop(%{state | reaping?: true})
  end

  defp continue_after_reap(state, :group, group) do
    case provider_identity_state(state, :group, group, state.group_alive_fun) do
      status when status in [:gone, :reused] -> maybe_reap_descendants(state)
      :unknown -> maybe_reap_group_descendants_or_wait(state, group)
      :live -> schedule_reap_retry(state)
    end
  end

  defp continue_after_reap(%{provider: %{process_group_id: group}} = state, :processes, _process_ids)
       when is_integer(group) and group > 0,
       do: continue_after_group_process_reap(state, group)

  defp continue_after_reap(
         %{
           owner_dead?: owner_dead?,
           provider_cleanup: provider_cleanup,
           provider: %{root_pid: root_pid, descendant_pids: process_ids}
         } = state,
         :processes,
         _process_ids
       )
       when (owner_dead? or provider_cleanup == :failed) and is_integer(root_pid) and root_pid > 0 and
              is_list(process_ids),
       do: maybe_reap_no_group_snapshot_or_retain(state)

  defp continue_after_reap(state, :processes, _process_ids) do
    case live_provider_processes(state) do
      %{live: [], unverified?: false} -> release_guardian(state)
      _ -> schedule_reap_retry(state)
    end
  end

  defp continue_after_reap(state, :root, root_pid) do
    case provider_identity_state(state, :root, root_pid, state.root_alive_fun) do
      status when status in [:gone, :reused] -> release_guardian(state)
      _ -> schedule_reap_retry(state)
    end
  end

  defp continue_after_reap(state, _kind, _identifier), do: loop(state)

  defp continue_after_group_process_reap(state, group) do
    case provider_identity_state(state, :group, group, state.group_alive_fun) do
      status when status in [:gone, :reused] -> maybe_reap_descendants(state)
      :unknown -> maybe_reap_group_descendants_or_wait(state, group)
      :live -> schedule_reap_retry(state)
    end
  end

  defp schedule_reap_retry(state) do
    Process.send_after(self(), :workspace_guardian_retry_reap, @reap_retry_ms)
    loop(%{state | reaping?: true})
  end

  defp release_guardian(state) do
    case Store.delete(state.lease.ticket, state.store) do
      :ok ->
        final_lease = %{state.lease | phase: :released}
        Registry.unregister(state.registry, state.lease.ticket)
        emit_telemetry(%{state | lease: final_lease}, :end, :released)

        Enum.each(state.waiters, fn waiter ->
          send(waiter, {:workspace_ownership_available, state.lease.ticket, self(), state.lease.generation})
        end)

        Enum.each(state.release_waiters, fn
          {from, ref, :release} -> reply(from, ref, :ok)
          {from, ref, :await} -> reply(from, ref, {:ok, final_lease})
        end)

        :ok

      {:error, _reason} ->
        schedule_reap_retry(update_phase(state, :reaping))
    end
  end

  defp update_phase(state, phase) do
    case Registry.update_value(state.registry, state.lease.ticket, &Map.put(&1, :phase, phase)) do
      {%{} = lease, _previous} ->
        next = %{state | lease: lease}
        _ = persist_state(next)

        if phase == :reaping and state.lease.phase != :reaping do
          emit_telemetry(next, :point, :reaping)
        end

        next

      _ ->
        state
    end
  end

  defp request_release(state, waiter) do
    %{state | release_requested?: true, release_waiters: [waiter | state.release_waiters]}
  end

  defp persist_state(state) do
    Store.put(state.lease.ticket, receipt(state), state.store)
  end

  defp receipt(state) do
    %{
      ticket: state.lease.ticket,
      generation: state.lease.generation,
      owner_id: state.lease.owner_id,
      phase: state.lease.phase,
      provider_expected?: state.provider_expected?,
      provider: state.provider,
      provider_cleanup: state.provider_cleanup
    }
  end

  defp emit_telemetry(state, boundary, outcome) do
    state.telemetry_fun.(state.lease, boundary, outcome)
  rescue
    _ -> :ok
  end

  defp safe_reap(reap_fun, identifier) do
    reap_fun.(identifier)
  rescue
    _ -> {:error, :reap_failed}
  end

  defp safe_reap(reap_fun, identifier, expected_identity) do
    case :erlang.fun_info(reap_fun, :arity) do
      {:arity, 2} -> reap_fun.(identifier, expected_identity)
      _ -> safe_reap(reap_fun, identifier)
    end
  rescue
    _ -> {:error, :reap_failed}
  end

  defp reap_fun_for(state, :group), do: state.reap_fun
  defp reap_fun_for(state, :root), do: state.root_reap_fun
  defp reap_fun_for(state, :processes), do: state.process_reap_fun

  defp reap_identifier(reap_fun, process_ids, expected_identities) when is_list(process_ids),
    do: Enum.each(process_ids, &safe_reap(reap_fun, &1, Map.get(expected_identities, &1, :unknown)))

  defp reap_identifier(reap_fun, identifier, expected_identity), do: safe_reap(reap_fun, identifier, expected_identity)

  defp capture_provider_identities(provider, process_identity_fun) do
    Enum.reduce(provider_identifiers(provider), provider, fn {kind, identifier}, provider ->
      identities = Map.get(provider, :process_identities, %{})
      key = {kind, identifier}

      if Map.has_key?(identities, key) do
        provider
      else
        Map.put(provider, :process_identities, Map.put(identities, key, capture_process_identity(process_identity_fun, identifier)))
      end
    end)
  end

  defp provider_identifiers(provider) do
    groups = identifier_entries(:group, Map.get(provider, :process_group_id))
    roots = identifier_entries(:root, Map.get(provider, :root_pid))

    processes =
      provider
      |> Map.get(:descendant_pids, [])
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> Enum.map(&{:process, &1})

    groups ++ roots ++ processes
  end

  defp identifier_entries(kind, identifier) when is_integer(identifier) and identifier > 0, do: [{kind, identifier}]
  defp identifier_entries(_kind, _identifier), do: []

  defp capture_process_identity(process_identity_fun, identifier) do
    case process_identity_fun.(identifier) do
      {:ok, identity} -> {:known, identity}
      :gone -> :gone
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp provider_identity_state(state, kind, identifier, alive_fun) do
    expected_identity = provider_identity(state, kind, identifier)

    compare_provider_identity(expected_identity, state.process_identity_fun, alive_fun, identifier)
  end

  defp provider_identity(%{provider: provider}, kind, identifier),
    do: provider_identity(provider, kind, identifier)

  defp provider_identity(provider, kind, identifier) when is_map(provider),
    do: provider |> Map.get(:process_identities, %{}) |> Map.get({kind, identifier})

  defp provider_identity(_provider, _kind, _identifier), do: :unknown

  defp reaping_identity(state, :processes, identifiers) when is_list(identifiers),
    do: Map.new(identifiers, &{&1, provider_identity(state, :process, &1)})

  defp reaping_identity(state, kind, identifier), do: provider_identity(state, kind, identifier)

  defp compare_provider_identity({:known, expected}, process_identity_fun, alive_fun, identifier) do
    case capture_process_identity(process_identity_fun, identifier) do
      {:known, ^expected} -> liveness_state(alive_fun, identifier, :live)
      {:known, _other_identity} -> :reused
      :gone -> liveness_state(alive_fun, identifier, :unknown)
      :unknown -> :unknown
    end
  end

  defp compare_provider_identity(:gone, _process_identity_fun, alive_fun, identifier),
    do: liveness_state(alive_fun, identifier, :unknown)

  defp compare_provider_identity(_expected, _process_identity_fun, _alive_fun, _identifier), do: :unknown

  defp liveness_state(alive_fun, identifier, alive_state) do
    if safely_alive?(alive_fun, identifier), do: alive_state, else: :gone
  end

  defp safely_alive?(alive_fun, identifier) do
    alive_fun.(identifier)
  rescue
    _ -> true
  end

  defp live_provider_processes(%{provider: provider} = state) do
    provider
    |> provider_process_identifiers()
    |> Enum.reduce(%{live: [], unverified?: false}, fn {kind, identifier}, result ->
      case provider_identity_state(state, kind, identifier, state.process_alive_fun) do
        :live -> %{result | live: [identifier | result.live]}
        :unknown -> %{result | unverified?: true}
        _ -> result
      end
    end)
    |> Map.update!(:live, &Enum.uniq/1)
  end

  defp provider_process_identifiers(provider) do
    roots = identifier_entries(:root, Map.get(provider, :root_pid))

    processes =
      provider
      |> Map.get(:descendant_pids, [])
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> Enum.map(&{:process, &1})

    Enum.uniq_by(roots ++ processes, fn {_kind, identifier} -> identifier end)
  end

  defp reply(pid, ref, result), do: send(pid, {:workspace_guardian_reply, ref, result})
end
