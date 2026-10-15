defmodule Aiur.AgentRunner.WorkspaceGuard do
  @moduledoc false

  require Logger
  alias Aiur.Orchestrator.StatusReason
  alias Aiur.RunTelemetry.Lifecycle
  alias Aiur.Signal
  alias Aiur.Workspace.{HostLock, Ownership}
  alias Aiur.Workspace.Ownership.{HoldStatus, Store}

  @spec run(Aiur.Issue.t(), pid() | nil, keyword(), String.t() | nil, fun()) :: :ok | {:error, term()}
  def run(issue, codex_update_recipient, opts, worker_host, attempt) do
    Logger.info("Starting worker attempt for #{Aiur.AgentRunner.issue_context(issue)} worker_host=#{worker_host || "local"}")

    attempt_id = Keyword.get(opts, :telemetry_attempt_id)
    setup_operation_id = "workspace:#{System.unique_integer([:positive, :monotonic])}"

    Lifecycle.record(issue.identifier, attempt_id, :workspace_setup, :start, %{
      operation_id: setup_operation_id,
      worker_host: worker_host,
      remote: is_binary(worker_host)
    })

    opts = Keyword.put(opts, :telemetry_setup_operation_id, setup_operation_id)

    lifecycle = %{ticket: issue.identifier, attempt_id: attempt_id}

    telemetry_fun = fn ownership, boundary, outcome ->
      record_workspace_ownership(issue, opts, boundary, outcome, ownership)
    end

    # The holder metadata lets the Orchestrator find this runner if it holds
    # the lease without a running entry: its update target died in an
    # Orchestrator crash, or a rolled-back state dropped its entry (#2705).
    holder = %{
      issue_id: issue.id,
      update_recipient: codex_update_recipient,
      update_recipient_name: registered_name(codex_update_recipient),
      worker_host: worker_host
    }

    case claim_after_reaping(issue.identifier, telemetry_fun, holder) do
      {:ok, ownership} ->
        try do
          with_workspace_host_lock(issue, opts, ownership, worker_host, fn ->
            attempt.(ownership, opts, lifecycle)
          end)
        after
          # The release request is intentionally distinct from the terminal
          # ownership boundary. A guardian may still be reaping a provider;
          # declaring the workspace free before registry removal would make
          # lifecycle telemetry lie about the generation that owns the cwd.
          case Ownership.release_and_wait(ownership) do
            {:ok, _released_ownership} ->
              :ok

            {:error, reason} ->
              Logger.warning("workspace ownership remains contained after release request issue=#{issue.identifier} reason=#{inspect(reason)}")
          end
        end

      {:error, {:workspace_owned, owner}} ->
        record_workspace_ownership_conflict(issue, opts, owner)
        record_setup_end(issue, opts, :contended, :workspace_owned)
        emit_ownership_conflict_alert(issue, owner)

        wait =
          if is_pid(codex_update_recipient) do
            Ownership.wait_for_release(issue.identifier, codex_update_recipient)
          else
            :waiting
          end

        notify_workspace_contention(codex_update_recipient, issue, owner, wait)
        :ok

      {:error, {:workspace_ownership_unavailable, reason}} ->
        record_setup_end(issue, opts, :failed, :workspace_ownership_unavailable)
        {:error, {:workspace_ownership_unavailable, reason}}
    end
  end

  # A backend swap stops its old runner before starting the replacement, but
  # the guardian may still be reaping that runner's provider. Waiting for that
  # exact generation to release avoids a routine refused dispatch and alert.
  # An active or provisioning owner remains a real competing session.
  defp claim_after_reaping(identifier, telemetry_fun, holder, retries \\ 1) do
    case Ownership.claim(identifier, Aiur.Workspace.Ownership.Registry, telemetry_fun: telemetry_fun, holder: holder) do
      {:error, {:workspace_owned, {:ok, %{phase: :reaping} = lease}}} = owned
      when retries > 0 and is_nil(holder.worker_host) ->
        maybe_release_and_reclaim(identifier, telemetry_fun, holder, lease, owned, retries)

      result ->
        result
    end
  end

  defp maybe_release_and_reclaim(identifier, telemetry_fun, holder, lease, owned, retries) do
    if local_reaping_provider?(identifier, lease) do
      case Ownership.release_and_wait(lease) do
        {:ok, _released} -> claim_after_reaping(identifier, telemetry_fun, holder, retries - 1)
        {:error, _reason} -> owned
      end
    else
      owned
    end
  end

  # A remote provider deliberately retains its reaping lease after owner death.
  # Releasing it from a new local attempt would discard that containment before
  # the remote workspace has been cleaned up. The durable receipt identifies
  # the old generation and its provider even after its owner process has died.
  defp local_reaping_provider?(identifier, %{generation: generation}) do
    case Store.get(identifier) do
      {:ok, %{generation: ^generation, provider: %{remote: true}}} ->
        false

      {:ok, %{generation: ^generation, provider: provider}} when is_map(provider) ->
        Map.has_key?(provider, :process_group_id) or Map.has_key?(provider, :root_pid) or
          Map.get(provider, :in_process) == true

      _ ->
        false
    end
  end

  defp registered_name(pid) when is_pid(pid) and node(pid) == node() do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> name
      _unnamed_or_dead -> nil
    end
  end

  defp registered_name(_recipient), do: nil

  # `Ownership.claim/3` excludes a second session inside *this* daemon, but the
  # workspace path is derived purely from repo and ticket, so a second daemon on
  # the same host that resolves the same repo would walk straight into the same
  # working tree (#2551). The filesystem is the only thing both daemons share,
  # so the host lock is the exclusion primitive; refusing here is the difference
  # between a loud, named refusal and two agents silently overwriting each
  # other's files while both report green gates.
  defp with_workspace_host_lock(issue, opts, ownership, worker_host, fun) do
    case HostLock.acquire_for_issue(issue.identifier, worker_host) do
      {:ok, lock} ->
        case HostLock.handoff_to_ownership(lock, ownership) do
          :ok ->
            fun.()

          {:error, reason} ->
            {:error, reason}
        end

      # A remote worker's workspace is on another machine's filesystem, so a
      # lock taken on this host would exclude nothing.
      :not_applicable ->
        fun.()

      {:error, {:workspace_locked, holder}} ->
        refuse_host_locked_workspace(issue, opts, holder)

      {:error, reason} ->
        record_setup_end(issue, opts, :failed, reason)
        {:error, reason}
    end
  end

  defp refuse_host_locked_workspace(issue, opts, holder) do
    description = HostLock.describe(holder)
    record_setup_end(issue, opts, :contended, :workspace_host_locked)

    Logger.error("Refusing to start a session for #{Aiur.AgentRunner.issue_context(issue)}: its workspace is already held by #{description}")

    emit_live_session_alert(issue, description)
    {:error, {:workspace_host_locked, holder}}
  end

  # A dispatch onto a ticket that already has a live session is exactly the
  # condition #2551 was filed for. It must reach an operator rather than be
  # left in the daemon log, and the message has to name the holder or the
  # operator cannot tell which daemon to look at.
  defp emit_live_session_alert(issue, description) do
    identifier = issue.identifier

    Signal.agent_alert(
      "ticket.#{identifier}.workspace.live_session",
      "Refused to dispatch #{identifier}: its workspace already has a live session held by #{description}.",
      issue: identifier,
      holder: description,
      needs_attention: true,
      severity: "warning"
    )

    :ok
  end

  defp emit_ownership_conflict_alert(issue, {:ok, %{phase: :reaping}} = owner) do
    case HoldStatus.for_ticket(issue.identifier) do
      %{generation: generation, proof: proof} when proof != :tracked_provider ->
        detail = StatusReason.render({:workspace_ownership_waiting, issue.identifier, generation, proof})

        Signal.agent_alert(
          "ticket.#{issue.identifier}.workspace.ownership_hold",
          "Refused to dispatch #{issue.identifier}: #{detail}.",
          issue: issue.identifier,
          workspace_generation: generation,
          recovery_proof: proof,
          needs_attention: true,
          severity: "warning"
        )

        :ok

      _ ->
        emit_live_session_alert(issue, describe_owner(owner))
    end
  end

  defp emit_ownership_conflict_alert(issue, owner), do: emit_live_session_alert(issue, describe_owner(owner))

  defp describe_owner({:ok, %{owner_id: owner_id, generation: generation}}),
    do: "this daemon's session owner=#{owner_id} generation=#{generation}"

  defp describe_owner(_owner), do: "another session in this daemon"

  @spec record_setup_end(Aiur.Issue.t(), keyword(), atom(), term()) :: :ok
  def record_setup_end(issue, opts, outcome, reason) do
    metadata = %{
      operation_id: Keyword.get(opts, :telemetry_setup_operation_id),
      outcome: outcome,
      reason_class: if(is_nil(reason), do: nil, else: Lifecycle.reason_class(reason))
    }

    Lifecycle.record(
      issue.identifier,
      Keyword.get(opts, :telemetry_attempt_id),
      :workspace_setup,
      :end,
      metadata
    )
  end

  defp record_workspace_ownership(issue, opts, boundary, outcome, ownership) do
    metadata =
      ownership
      |> Ownership.telemetry_metadata()
      |> Map.put(:outcome, outcome)

    Lifecycle.record(
      issue.identifier,
      Keyword.get(opts, :telemetry_attempt_id),
      :workspace_ownership,
      boundary,
      metadata
    )
  end

  defp record_workspace_ownership_conflict(issue, opts, {:ok, ownership}) do
    record_workspace_ownership(issue, opts, :point, :contended, ownership)
  end

  defp record_workspace_ownership_conflict(issue, opts, :none) do
    Lifecycle.record(
      issue.identifier,
      Keyword.get(opts, :telemetry_attempt_id),
      :workspace_ownership,
      :point,
      %{outcome: :contended}
    )
  end

  defp notify_workspace_contention(recipient, issue, owner, wait) when is_pid(recipient) do
    send(recipient, {:workspace_setup_contended, issue.id, issue.identifier, owner, wait})
    :ok
  end

  defp notify_workspace_contention(_recipient, _issue, _owner, _wait), do: :ok
end
