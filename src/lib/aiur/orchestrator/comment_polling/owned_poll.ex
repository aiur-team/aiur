defmodule Aiur.Orchestrator.CommentPolling.OwnedPoll do
  @moduledoc false
  @doc false
  @spec terminate_poll(map() | nil) :: :ok
  def terminate_poll(%{pid: pid, owner: owner, monitor_ref: monitor_ref})
      when is_pid(pid) and is_pid(owner) and is_reference(monitor_ref) do
    stop_ref = make_ref()
    owner_ref = Process.monitor(owner)
    send(owner, {:stop_owned_poll, self(), stop_ref})

    receive do
      {:owned_poll_stopped, ^stop_ref} ->
        Process.demonitor(owner_ref, [:flush])

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          0 -> Process.demonitor(monitor_ref, [:flush])
        end

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        # A completed poll owner can exit before the Orchestrator consumes its
        # result. If it died unexpectedly while the poll remains alive, reap
        # the tree here rather than hanging shutdown on a message to a dead pid.
        if Process.alive?(pid) do
          reap_process_tree(pid, monitor_ref)
        else
          Process.demonitor(monitor_ref, [:flush])
        end
    end

    :ok
  end

  def terminate_poll(%{owner: owner}) when is_pid(owner) do
    stop_ref = make_ref()
    owner_ref = Process.monitor(owner)
    send(owner, {:stop_owned_poll, self(), stop_ref})

    receive do
      {:owned_poll_stopped, ^stop_ref} -> Process.demonitor(owner_ref, [:flush])
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> :ok
    end

    :ok
  end

  def terminate_poll(_poll), do: :ok

  # The poll temporarily traps exits while Task.async_stream owns its target
  # tasks, so a link is not an inverse lifetime edge. The owner monitors the
  # Orchestrator, and the Orchestrator retains its owner monitor through the
  # acknowledged guarding handoff; either side's death therefore reaps the poll.
  @spec spawn_owned_poll(pid(), term(), reference(), (-> term()), term()) :: {pid(), reference()}
  def spawn_owned_poll(orchestrator, ownership_key, ref, task_fun, phase_hook) do
    spawn_monitor(fn ->
      orchestrator_ref = Process.monitor(orchestrator)

      case claim_poll_ownership(ownership_key, orchestrator, orchestrator_ref) do
        :ok ->
          {poll, poll_ref} = spawn_monitor(fn -> receive do: (:start -> task_fun.()) end)
          send(orchestrator, {:github_comment_poll_started, ref, self(), poll})
          await_poll_start(orchestrator, orchestrator_ref, ref, poll, poll_ref, phase_hook)

        :orchestrator_down ->
          :ok

        {:stop, caller, stop_ref} ->
          send(caller, {:owned_poll_stopped, stop_ref})
      end
    end)
  end

  defp await_poll_start(orchestrator, orchestrator_ref, ref, poll, poll_ref, phase_hook) do
    receive do
      {:start_owned_poll, ^orchestrator, ^ref} ->
        run_owner_phase_hook(phase_hook, :before_start, poll)
        send(poll, :start)
        run_owner_phase_hook(phase_hook, :after_start_before_guard, poll)
        send(orchestrator, {:github_comment_poll_guarding, ref, self(), poll})
        guard_poll_lifetime(orchestrator, orchestrator_ref, poll, poll_ref)

      {:stop_owned_poll, caller, stop_ref} ->
        reap_process_tree(poll, poll_ref)
        send(caller, {:owned_poll_stopped, stop_ref})

      {:DOWN, ^orchestrator_ref, :process, ^orchestrator, _reason} ->
        reap_process_tree(poll, poll_ref)
    end
  end

  defp claim_poll_ownership(ownership_key, orchestrator, orchestrator_ref) do
    key = {:github_comment_poll, ownership_key}

    case Registry.register(Aiur.Events.SubscriptionStoreRegistry, key, nil) do
      {:ok, _value} ->
        :ok

      {:error, {:already_registered, owner}} ->
        owner_ref = Process.monitor(owner)

        receive do
          {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
            claim_poll_ownership(ownership_key, orchestrator, orchestrator_ref)

          {:DOWN, ^orchestrator_ref, :process, ^orchestrator, _reason} ->
            Process.demonitor(owner_ref, [:flush])
            :orchestrator_down

          {:stop_owned_poll, caller, stop_ref} ->
            Process.demonitor(owner_ref, [:flush])
            {:stop, caller, stop_ref}
        end
    end
  end

  defp guard_poll_lifetime(orchestrator, orchestrator_ref, poll, poll_ref) do
    receive do
      {:DOWN, ^orchestrator_ref, :process, ^orchestrator, _reason} ->
        reap_process_tree(poll, poll_ref)

      {:stop_owned_poll, caller, stop_ref} ->
        reap_process_tree(poll, poll_ref)
        send(caller, {:owned_poll_stopped, stop_ref})

      {:DOWN, ^poll_ref, :process, ^poll, _reason} ->
        await_poll_release(orchestrator, orchestrator_ref)
    end
  end

  defp await_poll_release(orchestrator, orchestrator_ref) do
    receive do
      {:release_owned_poll, ^orchestrator, _ref} ->
        Process.demonitor(orchestrator_ref, [:flush])

      {:stop_owned_poll, caller, stop_ref} ->
        send(caller, {:owned_poll_stopped, stop_ref})

      {:DOWN, ^orchestrator_ref, :process, ^orchestrator, _reason} ->
        :ok
    end
  end

  defp run_owner_phase_hook(hook, phase, poll) when is_function(hook, 3), do: hook.(phase, self(), poll)
  defp run_owner_phase_hook(_hook, _phase, _poll), do: :ok

  @spec release_poll_owner(map() | nil) :: :ok | term()
  def release_poll_owner(%{owner: owner, ref: ref}) when is_pid(owner) and is_reference(ref) do
    send(owner, {:release_owned_poll, self(), ref})
  end

  def release_poll_owner(_poll), do: :ok

  @spec reap_poll_after_owner_down(map()) :: term()
  def reap_poll_after_owner_down(%{pid: pid, monitor_ref: monitor_ref} = poll)
      when is_pid(pid) and is_reference(monitor_ref) do
    if Process.alive?(pid) do
      reap_process_tree(pid, monitor_ref)
    else
      Process.demonitor(monitor_ref, [:flush])
    end

    demonitor_owner(poll)
  end

  def reap_poll_after_owner_down(poll), do: demonitor_owner(poll)

  @spec demonitor_owner(map()) :: term()
  def demonitor_owner(%{owner_monitor_ref: owner_monitor_ref}) when is_reference(owner_monitor_ref) do
    Process.demonitor(owner_monitor_ref, [:flush])
  end

  def demonitor_owner(_poll), do: :ok

  @spec reap_process_tree(pid(), reference()) :: :ok
  def reap_process_tree(root, root_ref) do
    descendants = linked_descendants(root, MapSet.new([self()]))
    descendant_refs = Enum.map(descendants, &{&1, Process.monitor(&1)})
    Process.exit(root, :kill)
    await_process_down(root, root_ref)
    Enum.each(descendant_refs, fn {pid, ref} -> await_process_down(pid, ref) end)
  end

  defp linked_descendants(pid, seen) do
    links =
      case Process.info(pid, :links) do
        {:links, linked} -> Enum.filter(linked, &(is_pid(&1) and not MapSet.member?(seen, &1)))
        nil -> []
      end

    Enum.reduce(links, links, fn linked, descendants ->
      nested = linked_descendants(linked, Enum.reduce(descendants, MapSet.put(seen, pid), &MapSet.put(&2, &1)))
      Enum.uniq(descendants ++ nested)
    end)
  end

  @spec await_process_down(pid(), reference()) :: :ok
  def await_process_down(pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  @spec demonitor_comment_poll(map()) :: term()
  def demonitor_comment_poll(poll) when is_map(poll) do
    case Map.get(poll, :monitor_ref) do
      monitor_ref when is_reference(monitor_ref) -> Process.demonitor(monitor_ref, [:flush])
      _missing -> :ok
    end

    demonitor_owner(poll)
  end
end
