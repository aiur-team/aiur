defmodule Aiur.Workspace.Ownership.Guardian do
  @moduledoc false

  alias Aiur.Claude.RemoteControl
  alias Aiur.Workspace.Ownership

  @reap_retry_ms 1_000

  @spec start(pid(), String.t(), pos_integer(), pid() | atom(), keyword()) :: pid()
  def start(owner, ticket, generation, registry, opts) do
    spawn(fn -> init(owner, ticket, generation, registry, opts) end)
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
        send(owner, {:workspace_guardian_claimed, self(), {:ok, lease}})

        loop(%{
          owner_ref: Process.monitor(owner),
          owner_dead?: false,
          registry: registry,
          lease: lease,
          provider_expected?: false,
          provider: nil,
          waiters: MapSet.new(),
          release_waiters: [],
          reap_fun: Keyword.get(opts, :reap_fun, &RemoteControl.graceful_kill_process_group/1),
          group_alive_fun: Keyword.get(opts, :group_alive_fun, &RemoteControl.process_group_alive?/1),
          root_reap_fun: Keyword.get(opts, :root_reap_fun, &RemoteControl.graceful_kill_tree/1),
          root_alive_fun: Keyword.get(opts, :root_alive_fun, &RemoteControl.process_alive?/1),
          reaping?: false,
          release_requested?: false
        })

      {:error, {:already_registered, _pid}} ->
        result = {:error, {:workspace_owned, Ownership.current(ticket, registry)}}
        send(owner, {:workspace_guardian_claimed, self(), result})
    end
  end

  defp loop(state) do
    receive do
      {:workspace_guardian_call, from, ref, {:activate, generation}} ->
        {reply, next} = activate(state, generation)
        reply(from, ref, reply)
        loop(next)

      {:workspace_guardian_call, from, ref, {:expect_provider, generation}} ->
        next = if generation == state.lease.generation, do: %{state | provider_expected?: true}, else: state
        reply(from, ref, :ok)
        loop(next)

      {:workspace_guardian_call, from, ref, {:track_provider, generation, provider}} ->
        next = track_provider(state, generation, provider)
        reply(from, ref, :ok)
        continue_after_provider_update(next)

      {:workspace_guardian_call, from, ref, {:track_process_group, generation, process_group_id}} ->
        next = track_provider(state, generation, %{process_group_id: process_group_id})
        reply(from, ref, :ok)
        continue_after_provider_update(next)

      {:workspace_guardian_call, from, ref, {:release, generation}} ->
        if generation == state.lease.generation,
          do:
            maybe_release_or_reap(%{
              state
              | release_requested?: true,
                release_waiters: [{from, ref, :release} | state.release_waiters]
            }),
          else:
            (
              reply(from, ref, :ok)
              loop(state)
            )

      {:workspace_guardian_call, from, ref, {:release_and_wait, generation}} ->
        if generation == state.lease.generation do
          maybe_release_or_reap(%{
            state
            | release_requested?: true,
              release_waiters: [{from, ref, :await} | state.release_waiters]
          })
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
      {%{generation: ^generation} = lease, _previous} -> {{:ok, lease}, %{state | lease: lease}}
      _ -> {{:error, :workspace_ownership_lost}, state}
    end
  end

  defp activate(state, _generation), do: {{:error, :workspace_ownership_lost}, state}

  defp track_provider(state, generation, provider) when generation == state.lease.generation and is_map(provider) do
    provider = Map.merge(state.provider || %{}, Map.take(provider, [:process_group_id, :root_pid, :remote]))
    %{state | provider_expected?: true, provider: provider}
  end

  defp track_provider(state, _generation, _provider), do: state

  # A live provider with no verified containment is deliberately fail-closed.
  # The owner may have died between OS spawn and metadata inspection; releasing
  # here would allow a retry to replace the provider's cwd underneath it.
  defp maybe_release_or_reap(%{provider: nil, provider_expected?: true, release_requested?: true} = state),
    do: release_guardian(state)

  defp maybe_release_or_reap(%{provider: nil, provider_expected?: true} = state) do
    loop(update_phase(state, :reaping))
  end

  defp maybe_release_or_reap(%{provider: nil} = state), do: release_guardian(state)

  defp maybe_release_or_reap(%{reaping?: true} = state), do: loop(state)

  defp maybe_release_or_reap(%{provider: %{remote: true}, release_requested?: true} = state),
    do: release_guardian(state)

  defp maybe_release_or_reap(%{provider: %{remote: true}} = state) do
    loop(update_phase(state, :reaping))
  end

  defp maybe_release_or_reap(%{provider: %{process_group_id: group}} = state)
       when is_integer(group) and group > 0 do
    if state.group_alive_fun.(group), do: start_reap(state, :group, group), else: release_guardian(state)
  end

  defp maybe_release_or_reap(%{provider: %{root_pid: root_pid}} = state)
       when is_integer(root_pid) and root_pid > 0 do
    if state.root_alive_fun.(root_pid), do: start_reap(state, :root, root_pid), else: release_guardian(state)
  end

  defp maybe_release_or_reap(state), do: loop(update_phase(state, :reaping))

  defp start_reap(state, kind, identifier) do
    state = update_phase(state, :reaping)
    guardian = self()
    reap_fun = if kind == :group, do: state.reap_fun, else: state.root_reap_fun

    spawn(fn ->
      _ = safe_reap(reap_fun, identifier)
      send(guardian, {:workspace_guardian_reaped, kind, identifier})
    end)

    loop(%{state | reaping?: true})
  end

  defp continue_after_reap(state, :group, group) do
    if state.group_alive_fun.(group), do: schedule_reap_retry(state), else: release_guardian(state)
  end

  defp continue_after_reap(state, :root, root_pid) do
    if state.root_alive_fun.(root_pid), do: schedule_reap_retry(state), else: release_guardian(state)
  end

  defp continue_after_reap(state, _kind, _identifier), do: loop(state)

  defp schedule_reap_retry(state) do
    Process.send_after(self(), :workspace_guardian_retry_reap, @reap_retry_ms)
    loop(%{state | reaping?: true})
  end

  defp release_guardian(state) do
    final_lease = %{state.lease | phase: :released}
    Registry.unregister(state.registry, state.lease.ticket)
    Enum.each(state.waiters, &send(&1, {:workspace_ownership_available, state.lease.ticket}))

    Enum.each(state.release_waiters, fn
      {from, ref, :release} -> reply(from, ref, :ok)
      {from, ref, :await} -> reply(from, ref, {:ok, final_lease})
    end)

    :ok
  end

  defp update_phase(state, phase) do
    case Registry.update_value(state.registry, state.lease.ticket, &Map.put(&1, :phase, phase)) do
      {%{} = lease, _previous} -> %{state | lease: lease}
      _ -> state
    end
  end

  defp safe_reap(reap_fun, identifier) do
    reap_fun.(identifier)
  rescue
    _ -> {:error, :reap_failed}
  end

  defp reply(pid, ref, result), do: send(pid, {:workspace_guardian_reply, ref, result})
end
