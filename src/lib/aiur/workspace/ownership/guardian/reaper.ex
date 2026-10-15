defmodule Aiur.Workspace.Ownership.Guardian.Reaper do
  @moduledoc false

  require Logger

  alias Aiur.Workspace.Ownership.Guardian.{Provider, Receipt}
  alias Aiur.Workspace.Ownership.Retention

  # A live provider with no verified containment is deliberately fail-closed.
  # The owner may have died between OS process creation and metadata inspection; releasing
  # here would allow a retry to replace the provider's cwd underneath it.
  @spec maybe_release_or_reap(map()) :: tuple()
  def maybe_release_or_reap(%{provider_cleanup: :succeeded} = state),
    do: {:release, state}

  def maybe_release_or_reap(%{provider: nil, provider_expected?: true, release_requested?: true} = state) do
    if local_provider_exited_after_reboot?(state), do: {:release, state}, else: {:wait, Receipt.update_phase(Retention.mark(state), :reaping)}
  end

  def maybe_release_or_reap(%{provider: nil, provider_expected?: true} = state) do
    if local_provider_exited_after_reboot?(state) do
      case record_provider_exit_audit(state, "guardian", "workspace_hold_auto_release") do
        :ok ->
          Logger.warning("Automatically released workspace ownership with verified provider-exit proof ticket=#{state.lease.ticket} generation=#{state.lease.generation}")
          Receipt.emit_telemetry(state, :point, :automatic_release_after_provider_exit_proof)
          {:release, state}

        {:error, reason} ->
          Logger.error("Workspace recovery audit write failed ticket=#{state.lease.ticket} generation=#{state.lease.generation} reason=#{inspect(reason)}")
          {:wait, Receipt.update_phase(Retention.mark(state, "recovery_audit_failed"), :reaping)}
      end
    else
      {:wait, Receipt.update_phase(Retention.mark(state), :reaping)}
    end
  end

  def maybe_release_or_reap(%{provider: nil} = state), do: {:release, state}

  def maybe_release_or_reap(%{reaping?: true} = state), do: {:wait, state}

  def maybe_release_or_reap(%{provider: %{remote: true}, release_requested?: true} = state),
    do: {:release, state}

  # A remote provider has no local PID or reaper; time passing cannot prove its cwd is unused.
  # Retain its generation after abrupt local-owner death rather than letting a retry remove that cwd.
  def maybe_release_or_reap(%{provider: %{remote: true}} = state),
    do: {:wait, Receipt.update_phase(Retention.mark(state), :reaping)}

  # An in-process session (an OpenAI-compatible HTTP agent) has no OS process to
  # reap: it is a child of the runner and dies with it. Release the lease on
  # owner death or a clean release, exactly as if the provider had been proven
  # gone — there is nothing that could have survived the owner. If the provider
  # later also reports an OS identity (a process group, root, remote host, or
  # descendants), that containment takes precedence and normal reaping applies;
  # strip the marker and re-enter so it is never released early.
  def maybe_release_or_reap(%{provider: %{in_process: true} = provider} = state) do
    if Provider.in_process_only?(provider) do
      {:release, state}
    else
      maybe_release_or_reap(%{state | provider: Map.delete(provider, :in_process)})
    end
  end

  def maybe_release_or_reap(%{provider: %{process_group_id: group}} = state)
      when is_integer(group) and group > 0 do
    case Provider.provider_identity_state(state, :group, group, state.group_alive_fun) do
      :live -> {:reap, state, :group, group}
      status when status in [:gone, :reused] -> maybe_reap_descendants(state)
      :unknown -> maybe_reap_group_descendants_or_wait(state, group)
    end
  end

  # A no-group snapshot cannot prove that an abruptly dead provider has no
  # reparented or late children. Reap identities we did observe, but retain the
  # generation once that snapshot is exhausted rather than reprovisioning its cwd.
  def maybe_release_or_reap(
        %{
          owner_dead?: owner_dead?,
          provider_cleanup: provider_cleanup,
          provider: %{root_pid: root_pid, descendant_pids: process_ids}
        } = state
      )
      when (owner_dead? or provider_cleanup == :failed) and is_integer(root_pid) and root_pid > 0 and
             is_list(process_ids),
      do: maybe_reap_no_group_snapshot_or_retain(state)

  def maybe_release_or_reap(%{provider: %{root_pid: root_pid, descendant_pids: process_ids}} = state)
      when is_integer(root_pid) and root_pid > 0 and is_list(process_ids),
      do: maybe_reap_descendants(state)

  def maybe_release_or_reap(%{provider: %{root_pid: root_pid}} = state)
      when is_integer(root_pid) and root_pid > 0,
      do: maybe_reap_root(state, root_pid)

  def maybe_release_or_reap(state), do: {:wait, Receipt.update_phase(state, :reaping)}

  defp local_provider_exited_after_reboot?(%{provider_scope: :local, provider_boot_id: previous} = state)
       when is_binary(previous) and previous != "" do
    case state.host_boot_id_fun.() do
      {:ok, current} when is_binary(current) and current != "" -> current != previous
      _ -> false
    end
  rescue
    _ -> false
  end

  defp local_provider_exited_after_reboot?(_state), do: false

  defp maybe_reap_descendants(state) do
    case Provider.live_provider_processes(state) do
      %{live: [], unverified?: false} -> {:release, state}
      %{live: [], unverified?: true} -> {:retry, state}
      %{live: live_process_ids} -> {:reap, state, :processes, live_process_ids}
    end
  end

  defp maybe_reap_no_group_snapshot_or_retain(state) do
    case Provider.live_provider_processes(state) do
      %{live: live_process_ids} when live_process_ids != [] -> {:reap, state, :processes, live_process_ids}
      _ -> {:wait, Receipt.update_phase(state, :reaping)}
    end
  end

  # A group can outlive its leader or its one-time descendant snapshot. The
  # group identifier is unsafe to signal unless the leader identity still
  # matches, so release only after the group probe and recorded children agree.
  defp maybe_reap_group_descendants_or_wait(state, group) do
    case Provider.live_provider_processes(state) do
      %{live: [], unverified?: false} ->
        if Provider.safely_alive?(state.group_alive_fun, group), do: {:retry, state}, else: {:release, state}

      %{live: [], unverified?: true} ->
        {:retry, state}

      %{live: live_process_ids} ->
        {:reap, state, :processes, live_process_ids}
    end
  end

  defp maybe_reap_root(state, root_pid) do
    case Provider.provider_identity_state(state, :root, root_pid, state.root_alive_fun) do
      :live -> {:reap, state, :root, root_pid}
      status when status in [:gone, :reused] -> {:release, state}
      :unknown -> {:retry, state}
    end
  end

  @spec continue_after_reap(map(), atom(), term()) :: tuple()
  def continue_after_reap(state, :group, group) do
    case Provider.provider_identity_state(state, :group, group, state.group_alive_fun) do
      status when status in [:gone, :reused] -> maybe_reap_descendants(state)
      :unknown -> maybe_reap_group_descendants_or_wait(state, group)
      :live -> {:retry, state}
    end
  end

  def continue_after_reap(%{provider: %{process_group_id: group}} = state, :processes, _process_ids)
      when is_integer(group) and group > 0,
      do: continue_after_group_process_reap(state, group)

  def continue_after_reap(
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

  def continue_after_reap(state, :processes, _process_ids) do
    case Provider.live_provider_processes(state) do
      %{live: [], unverified?: false} -> {:release, state}
      _ -> {:retry, state}
    end
  end

  def continue_after_reap(state, :root, root_pid) do
    case Provider.provider_identity_state(state, :root, root_pid, state.root_alive_fun) do
      status when status in [:gone, :reused] -> {:release, state}
      _ -> {:retry, state}
    end
  end

  def continue_after_reap(state, _kind, _identifier), do: {:wait, state}

  defp continue_after_group_process_reap(state, group) do
    case Provider.provider_identity_state(state, :group, group, state.group_alive_fun) do
      status when status in [:gone, :reused] -> maybe_reap_descendants(state)
      :unknown -> maybe_reap_group_descendants_or_wait(state, group)
      :live -> {:retry, state}
    end
  end

  @spec release_with_provider_exit_proof(map(), term()) :: tuple()
  def release_with_provider_exit_proof(%{lease: %{generation: generation, phase: :reaping}, provider: nil, provider_expected?: true} = state, generation) do
    if local_provider_exited_after_reboot?(state) do
      case record_provider_exit_audit(state, System.get_env("USER") || "unknown", "workspace_hold_release") do
        :ok ->
          Logger.warning("Operator released workspace ownership with verified provider-exit proof ticket=#{state.lease.ticket} generation=#{state.lease.generation}")
          Receipt.emit_telemetry(state, :point, :operator_release_after_provider_exit_proof)
          {:ok, state}

        {:error, reason} ->
          Logger.error("Workspace recovery audit write failed ticket=#{state.lease.ticket} generation=#{generation} reason=#{inspect(reason)}")
          {{:error, {:audit_write_failed, reason}}, state}
      end
    else
      {{:error, :cannot_release_without_exit_proof}, state}
    end
  end

  def release_with_provider_exit_proof(state, _generation), do: {{:error, :workspace_ownership_lost}, state}

  defp record_provider_exit_audit(state, actor, action) do
    record = %{
      action: action,
      actor: actor,
      generation: state.lease.generation,
      proof: "local_host_boot_id_changed",
      ticket: state.lease.ticket,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    safe_audit(state.audit_fun, record)
  end

  defp safe_audit(audit_fun, record) do
    case audit_fun.(record) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_audit_result, other}}
    end
  rescue
    error -> {:error, {:audit_callback_failed, error}}
  catch
    kind, reason -> {:error, {:audit_callback_failed, {kind, reason}}}
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

  @spec reap_fun_for(map(), atom()) :: function()
  def reap_fun_for(state, :group), do: state.reap_fun
  def reap_fun_for(state, :root), do: state.root_reap_fun
  def reap_fun_for(state, :processes), do: state.process_reap_fun

  @spec reap_identifier(function(), term(), term()) :: term()
  def reap_identifier(reap_fun, process_ids, expected_identities) when is_list(process_ids),
    do: Enum.each(process_ids, &safe_reap(reap_fun, &1, Map.get(expected_identities, &1, :unknown)))

  def reap_identifier(reap_fun, identifier, expected_identity), do: safe_reap(reap_fun, identifier, expected_identity)
end
