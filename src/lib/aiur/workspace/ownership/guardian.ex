defmodule Aiur.Workspace.Ownership.Guardian do
  @moduledoc false

  alias Aiur.ProcessTree
  alias Aiur.Workspace.{HostBoot, HostLock}
  alias Aiur.Workspace.Ownership
  alias Aiur.Workspace.Ownership.{AuditLog, Retention, Store}
  alias Aiur.Workspace.Ownership.Guardian.{Provider, Reaper, Receipt}

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
          registry
          |> runtime_state(
            lease,
            Process.monitor(owner),
            false,
            %{
              provider_expected?: false,
              provider: nil,
              provider_cleanup: :not_started,
              provider_scope: :unknown,
              provider_boot_id: nil
            },
            opts
          )

        publish_holder(registry, lease, owner, opts)

        case Receipt.persist_state(state) do
          :ok ->
            Receipt.emit_telemetry(state, :start, :claimed)
            send(owner, {:workspace_guardian_claimed, self(), {:ok, lease}})
            loop(state)

          {:error, reason} ->
            Registry.unregister(registry, holder_key(ticket))
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
      retained_since: receipt["retained_since"],
      retained_cause: receipt["retained_cause"],
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
      provider_scope: Map.get(receipt, :provider_scope, :unknown),
      provider_boot_id: Map.get(receipt, :provider_boot_id),
      host_boot_id_fun: Keyword.get(opts, :host_boot_id_fun, &HostBoot.id/0),
      before_notify_fun: Keyword.get(opts, :before_notify_fun, fn _waiter -> :ok end),
      waiters: MapSet.new(),
      release_waiters: [],
      reap_fun: Keyword.get(opts, :reap_fun, &ProcessTree.reap_process_group/2),
      group_alive_fun: Keyword.get(opts, :group_alive_fun, &ProcessTree.process_group_alive?/1),
      root_reap_fun: Keyword.get(opts, :root_reap_fun, &ProcessTree.reap_process_tree/2),
      root_alive_fun: Keyword.get(opts, :root_alive_fun, &ProcessTree.process_alive?/1),
      process_reap_fun: Keyword.get(opts, :process_reap_fun, &ProcessTree.reap_process/2),
      process_alive_fun: Keyword.get(opts, :process_alive_fun, &ProcessTree.process_alive?/1),
      process_identity_fun: Keyword.get(opts, :process_identity_fun, &ProcessTree.process_identity/1),
      telemetry_fun: Keyword.get(opts, :telemetry_fun, fn _lease, _boundary, _outcome -> :ok end),
      audit_fun: Keyword.get(opts, :audit_fun, &AuditLog.write/1),
      host_lock: Map.get(receipt, :host_lock),
      reaping?: false,
      release_requested?: false
    }
  end

  @doc false
  @spec holder_key(String.t()) :: {:holder, String.t()}
  def holder_key(ticket), do: {:holder, ticket}

  # A claimed generation publishes its live owner and claim metadata as a
  # second registry entry for ETS reads without calling a store-blocked guardian.
  defp publish_holder(registry, lease, owner, opts) do
    holder =
      case Keyword.get(opts, :holder) do
        holder when is_map(holder) -> holder
        _other -> %{}
      end

    _ = Registry.register(registry, holder_key(lease.ticket), %{generation: lease.generation, owner: owner, holder: holder})
    :ok
  end

  defp loop(state) do
    receive do
      {:workspace_guardian_call, from, ref, {:activate, generation}} ->
        {reply, next} = activate(state, generation)
        reply(from, ref, reply)
        loop(next)

      {:workspace_guardian_call, from, ref, {:expect_provider, generation, scope}} ->
        {reply_value, next} = expect_provider(state, generation, scope)
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

      {:workspace_guardian_call, from, ref, {:track_host_lock, generation, lock}} ->
        {reply_value, next} = track_host_lock(state, generation, lock)
        reply(from, ref, reply_value)
        loop(next)

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

      {:workspace_guardian_call, from, ref, {:release_with_provider_exit_proof, generation}} ->
        {reply_value, next} = Reaper.release_with_provider_exit_proof(state, generation)

        if reply_value == :ok do
          maybe_release_or_reap(request_release(next, {from, ref, :release}))
        else
          reply(from, ref, reply_value)
          loop(next)
        end

      {:workspace_guardian_call, from, ref, {:wait_for_release, recipient}} when is_pid(recipient) ->
        # Store the waiter before acknowledging it. The acknowledgement carries
        # this exact generation so a subscriber can reject an ABA replacement.
        next = %{state | waiters: MapSet.put(state.waiters, recipient)}
        reply(from, ref, {:waiting, state.lease.generation})
        loop(next)

      {:DOWN, owner_ref, :process, _owner, _reason} when owner_ref == state.owner_ref ->
        Registry.unregister(state.registry, holder_key(state.lease.ticket))
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

        case Receipt.persist_state(next) do
          :ok ->
            Receipt.emit_telemetry(next, :point, :active)
            {{:ok, lease}, next}

          {:error, _reason} ->
            {{:error, :workspace_ownership_lost}, next}
        end

      _ ->
        {{:error, :workspace_ownership_lost}, state}
    end
  end

  defp activate(state, _generation), do: {{:error, :workspace_ownership_lost}, state}

  defp expect_provider(%{lease: %{generation: generation, phase: phase}} = state, generation, scope)
       when phase in [:provisioning, :active] do
    {scope, boot_id} = provider_boot_proof(scope, state.host_boot_id_fun)

    Receipt.persist_update(state, %{
      state
      | provider_expected?: true,
        provider_cleanup: :unresolved,
        provider_scope: scope,
        provider_boot_id: boot_id
    })
  end

  defp expect_provider(state, _generation, _scope), do: {{:error, :workspace_ownership_lost}, state}

  defp provider_boot_proof(:local, boot_id_fun) do
    case boot_id_fun.() do
      {:ok, boot_id} when is_binary(boot_id) and boot_id != "" -> {:local, boot_id}
      _ -> {:unknown, nil}
    end
  rescue
    _ -> {:unknown, nil}
  end

  defp provider_boot_proof(:remote, _boot_id_fun), do: {:remote, nil}
  defp provider_boot_proof(_scope, _boot_id_fun), do: {:unknown, nil}

  defp cancel_provider_expectation(%{lease: %{generation: generation}, provider: nil} = state, generation),
    do:
      Receipt.persist_update(state, %{
        state
        | provider_expected?: false,
          provider_cleanup: :not_started,
          provider_scope: :unknown,
          provider_boot_id: nil
      })

  defp cancel_provider_expectation(state, _generation), do: {{:error, :workspace_ownership_lost}, state}

  defp track_provider(%{lease: %{generation: generation, phase: phase}} = state, generation, provider)
       when phase in [:provisioning, :active] and is_map(provider) do
    provider =
      state.provider
      |> Kernel.||(%{})
      |> Provider.merge_provider(provider)
      |> Provider.capture_provider_identities(state.process_identity_fun)

    if Provider.valid_provider?(provider) do
      Receipt.persist_update(state, %{state | provider_expected?: true, provider: provider})
    else
      {{:error, :workspace_ownership_lost}, state}
    end
  end

  defp track_provider(state, _generation, _provider), do: {{:error, :workspace_ownership_lost}, state}

  # The runner can be killed without running its `after` block. Keep the
  # filesystem lock with the guardian, whose lifetime already covers provider
  # reaping, so a same-daemon replacement cannot be stranded behind the live
  # BEAM pid or race an unreaped provider.
  defp track_host_lock(%{lease: %{generation: generation, phase: phase}} = state, generation, lock)
       when phase in [:provisioning, :active] do
    Receipt.persist_update(state, %{state | host_lock: lock})
  end

  defp track_host_lock(state, _generation, _lock), do: {{:error, :workspace_ownership_lost}, state}

  defp mark_provider_cleanup_unknown(%{lease: %{generation: generation, phase: phase}} = state, generation)
       when phase in [:provisioning, :active] do
    next =
      if state.provider_cleanup == :succeeded,
        do: state,
        else: %{state | provider_cleanup: :failed}

    Receipt.persist_update(state, next)
  end

  defp mark_provider_cleanup_unknown(state, _generation), do: {{:error, :workspace_ownership_lost}, state}

  defp mark_provider_cleanup_succeeded(%{lease: %{generation: generation, phase: phase}} = state, generation)
       when phase in [:provisioning, :active],
       do: Receipt.persist_update(state, %{state | provider_cleanup: :succeeded})

  defp mark_provider_cleanup_succeeded(state, _generation), do: {{:error, :workspace_ownership_lost}, state}

  defp maybe_release_or_reap(state), do: state |> Reaper.maybe_release_or_reap() |> apply_reap_action()

  defp continue_after_reap(state, kind, identifier),
    do: state |> Reaper.continue_after_reap(kind, identifier) |> apply_reap_action()

  defp apply_reap_action({:release, state}), do: release_guardian(state)
  defp apply_reap_action({:wait, state}), do: loop(state)
  defp apply_reap_action({:retry, state}), do: schedule_reap_retry(state)
  defp apply_reap_action({:reap, state, kind, identifier}), do: start_reap(state, kind, identifier)

  defp start_reap(state, kind, identifier) do
    state = Receipt.update_phase(state, :reaping)
    guardian = self()
    reap_fun = Reaper.reap_fun_for(state, kind)
    expected_identity = Provider.reaping_identity(state, kind, identifier)

    spawn(fn ->
      Reaper.reap_identifier(reap_fun, identifier, expected_identity)
      send(guardian, {:workspace_guardian_reaped, kind, identifier})
    end)

    loop(%{state | reaping?: true})
  end

  defp schedule_reap_retry(state) do
    Process.send_after(self(), :workspace_guardian_retry_reap, @reap_retry_ms)
    loop(%{state | reaping?: true})
  end

  defp release_guardian(state) do
    case Store.delete(state.lease.ticket, state.store) do
      :ok ->
        HostLock.release(state.host_lock)
        final_lease = %{state.lease | phase: :released}
        Registry.unregister(state.registry, holder_key(state.lease.ticket))
        Registry.unregister(state.registry, state.lease.ticket)
        Receipt.emit_telemetry(%{state | lease: final_lease}, :end, :released)
        Retention.resolve(final_lease)

        Enum.each(state.waiters, fn waiter ->
          state.before_notify_fun.(waiter)
          send(waiter, {:workspace_ownership_available, state.lease.ticket, self(), state.lease.generation})
        end)

        Enum.each(state.release_waiters, fn
          {from, ref, :release} -> reply(from, ref, :ok)
          {from, ref, :await} -> reply(from, ref, {:ok, final_lease})
        end)

        :ok

      {:error, _reason} ->
        schedule_reap_retry(Receipt.update_phase(state, :reaping))
    end
  end

  defp request_release(state, waiter) do
    %{state | release_requested?: true, release_waiters: [waiter | state.release_waiters]}
  end

  defp reply(pid, ref, result), do: send(pid, {:workspace_guardian_reply, ref, result})
end
