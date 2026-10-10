defmodule Aiur.Workspace.OwnershipRetentionTest do
  use Aiur.TestSupport

  @moduletag timeout: 15_000

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI
  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.{State, StatusReason, StatusReport, WaitingReason}
  alias Aiur.Workspace.Ownership
  alias Aiur.Workspace.Ownership.{Guardian, Retention, Store}

  test "unrecorded provider owner death stamps and alerts once, including restoration" do
    {ticket, lease, topic} = retained_owner(nil)
    receive_barrier({:event, %{"topic" => ^topic, "needs_attention" => true, "since" => since, "provider" => nil}})
    assert {:error, :workspace_ownership_lost} = Ownership.mark_provider_cleanup_unknown(lease)
    assert {:ok, %{phase: :reaping, retained_since: ^since}} = Ownership.current(ticket)
    assert Retention.for_ticket(ticket).cause == "provider_unrecorded"

    send(lease.guardian, :workspace_guardian_retry_reap)
    assert {:error, :workspace_ownership_lost} = Ownership.mark_provider_cleanup_unknown(lease)
    assert {:ok, receipt} = Store.get(ticket)
    assert receipt["retained_since"] == since
    refute_received {:event, %{"topic" => ^topic}}

    stop_guardian(lease.guardian)
    assert {:ok, restored} = Guardian.restore(receipt, Aiur.Workspace.Ownership.Registry, [])
    on_exit(fn -> stop_guardian(restored.guardian) end)
    assert {:error, :workspace_ownership_lost} = Ownership.mark_provider_cleanup_unknown(restored)
    assert Retention.for_ticket(ticket).since == since
    refute_received {:event, %{"topic" => ^topic}}
  end

  test "remote owner death retains its lease with one provider-specific alert" do
    provider = %{remote: true}
    {ticket, lease, topic} = retained_owner(provider)
    receive_barrier({:event, %{"topic" => ^topic, "needs_attention" => true, "provider" => ^provider, "since" => since}})
    assert {:error, :workspace_ownership_lost} = Ownership.mark_provider_cleanup_unknown(lease)
    assert Retention.for_ticket(ticket) == %{since: since, cause: "remote_provider_exit_unproven", generation: lease.generation}
    send(lease.guardian, :workspace_guardian_retry_reap)
    assert {:error, :workspace_ownership_lost} = Ownership.mark_provider_cleanup_unknown(lease)
    refute_received {:event, %{"topic" => ^topic}}
    assert :ok = Ownership.release(lease)
    assert :none = Ownership.current(ticket)
  end

  test "release timeout reports error while the lease stays held and late cleanup clears it" do
    boot = start_supervised!({Agent, fn -> "boot-before" end})
    {ticket, lease, topic} = retained_owner(nil, host_boot_id_fun: fn -> {:ok, Agent.get(boot, & &1)} end)
    :ok = Exchange.subscribe(topic <> ".resolved")
    receive_barrier({:event, %{"topic" => ^topic}})
    assert {:error, :release_timeout} = Ownership.release(lease)
    assert Ownership.protected?(ticket)
    assert %{generation: generation} = Retention.for_ticket(ticket)
    assert generation == lease.generation
    assert {:error, {:workspace_owned, {:ok, %{generation: ^generation}}}} = Ownership.claim(ticket)
    monitor = Process.monitor(lease.guardian)
    Agent.update(boot, fn _ -> "boot-after" end)
    send(lease.guardian, :workspace_guardian_retry_reap)
    receive_barrier({:DOWN, ^monitor, :process, _, :normal})
    resolved = topic <> ".resolved"
    receive_barrier({:event, %{"topic" => ^resolved, "needs_attention" => false}})
    assert Retention.for_ticket(ticket) == nil
    assert :none = Ownership.current(ticket)
    refute_received {:event, %{"topic" => ^topic}}
  end

  test "retained reason, owner, cause and age reach idle and running fleet rows and CLI" do
    {ticket, lease, topic} = retained_owner(nil)
    receive_barrier({:event, %{"topic" => ^topic}})
    assert {:error, :workspace_ownership_lost} = Ownership.mark_provider_cleanup_unknown(lease)
    {:ok, receipt} = Store.get(ticket)
    since = DateTime.add(DateTime.utc_now(), -45, :second) |> DateTime.to_iso8601()
    stop_guardian(lease.guardian)
    {:ok, restored} = Guardian.restore(Map.put(receipt, "retained_since", since), Aiur.Workspace.Ownership.Registry, [])
    on_exit(fn -> stop_guardian(restored.guardian) end)
    assert {:error, :workspace_ownership_lost} = Ownership.mark_provider_cleanup_unknown(restored)
    issue = %Issue{id: ticket, identifier: ticket, state: "in-progress"}
    idle = %State{last_polled_issues: %{ticket => issue}, startup_claim_reconciliation_complete?: true}
    entry = %{identifier: ticket, issue: issue, session_id: "session", started_at: DateTime.utc_now(), control: %{status: :working}}
    running = %{idle | running: %{ticket => entry}}

    for {state, kind} <- [{idle, :idle}, {running, :running}] do
      [row] = StatusReport.agent_statuses(state)
      [snapshot_row] = Map.fetch!(StatusReport.snapshot_payload(StatusReport.snapshot_input(state)), kind)

      for waiting <- [row.waiting, snapshot_row.waiting] do
        assert waiting.reason == :workspace_retained
        assert waiting.owner == "Workspace.Ownership"
        assert waiting.cause == "provider_unrecorded"
        assert waiting.since == since
        assert waiting.age_ms >= 45_000
        assert waiting.age_ms < 60_000
      end

      output = capture_io(fn -> AgentControlCLI.agents(fleet_view: {:ok, StatusReport.snapshot_payload(state), %{status: :current, age_seconds: 0}}) end)
      assert output =~ ~r/· workspace_retained · Workspace.Ownership · \d+s/
      assert Jason.decode!(Jason.encode!(row.waiting))["since"] == since
    end

    assert WaitingReason.for_running(%{workspace_retained?: true}) == :workspace_retained
    assert WaitingReason.for_running(%{workspace_retained?: true, open_decision_count: 1}) == :waiting_for_human
  end

  test "verified reboot with a failed recovery audit names the audit failure without another alert" do
    boot = start_supervised!({Agent, fn -> "boot-before" end})

    {ticket, lease, topic} =
      retained_owner(nil,
        host_boot_id_fun: fn -> {:ok, Agent.get(boot, & &1)} end,
        audit_fun: fn _ -> {:error, :eacces} end
      )

    receive_barrier({:event, %{"topic" => ^topic, "since" => since}})
    Agent.update(boot, fn _ -> "boot-after" end)
    send(lease.guardian, :workspace_guardian_retry_reap)
    assert {:error, :workspace_ownership_lost} = Ownership.mark_provider_cleanup_unknown(lease)
    assert Retention.for_ticket(ticket) == %{since: since, cause: "recovery_audit_failed", generation: lease.generation}
    refute_received {:event, %{"topic" => ^topic}}
    issue = %Issue{id: ticket, identifier: ticket, state: "in-progress"}
    [row] = StatusReport.agent_statuses(%State{last_polled_issues: %{ticket => issue}})
    assert row.waiting.cause == "recovery_audit_failed"
    assert StatusReason.render(row.reason) =~ "retry with aiur workspace-recover #{ticket} #{lease.generation}"
  end

  test "missing retention evidence keeps cause and start unknown through JSON and CLI" do
    row = %{issue_id: "unknown-retention", identifier: "unknown-retention", waiting_reason: :workspace_retained}

    for evidence <- [nil, %{}, %{cause: nil, since: nil}] do
      attached = WaitingReason.attach(Map.put(row, :workspace_retention, evidence), %State{})
      assert attached.waiting.reason == :workspace_retained
      assert attached.waiting.cause == :unknown
      assert attached.waiting.since == nil
      assert attached.waiting.age_ms == nil
      json = attached |> WaitingReason.public_wait() |> Jason.encode!() |> Jason.decode!()
      assert json["cause"] == "unknown"
      assert json["since"] == nil
      assert json["age_ms"] == nil
      assert WaitingReason.render_wait(attached) == " · workspace_retained · Workspace.Ownership · since unknown"
    end
  end

  test "legacy restored lease keeps its unknown start across retries and restoration" do
    {ticket, lease, topic} = retained_owner(nil)
    receive_barrier({:event, %{"topic" => ^topic}})
    assert {:error, :workspace_ownership_lost} = Ownership.mark_provider_cleanup_unknown(lease)
    {:ok, receipt} = Store.get(ticket)
    stop_guardian(lease.guardian)
    legacy = Map.drop(receipt, ["retained_since", "retained_cause"])
    {:ok, restored} = Guardian.restore(legacy, Aiur.Workspace.Ownership.Registry, [])
    on_exit(fn -> stop_guardian(restored.guardian) end)
    receive_barrier({:event, %{"topic" => ^topic, "since" => nil}})
    assert {:error, :workspace_ownership_lost} = Ownership.mark_provider_cleanup_unknown(restored)
    assert Retention.for_ticket(ticket) == %{since: nil, cause: "provider_unrecorded", generation: lease.generation}
    send(restored.guardian, :workspace_guardian_retry_reap)
    assert {:error, :workspace_ownership_lost} = Ownership.mark_provider_cleanup_unknown(restored)
    refute_received {:event, %{"topic" => ^topic}}
    issue = %Issue{id: ticket, identifier: ticket, state: "in-progress"}
    [row] = StatusReport.agent_statuses(%State{last_polled_issues: %{ticket => issue}})
    assert row.waiting.reason == :workspace_retained
    assert row.waiting.since == nil
    assert row.waiting.age_ms == nil
    assert WaitingReason.render_wait(row) =~ "since unknown"
    {:ok, saved} = Store.get(ticket)
    assert saved["retained_since"] == nil
    stop_guardian(restored.guardian)
    {:ok, again} = Guardian.restore(saved, Aiur.Workspace.Ownership.Registry, [])
    on_exit(fn -> stop_guardian(again.guardian) end)
    assert {:error, :workspace_ownership_lost} = Ownership.mark_provider_cleanup_unknown(again)
    assert Retention.for_ticket(ticket).since == nil
    refute_received {:event, %{"topic" => ^topic}}
  end

  defp retained_owner(provider, opts \\ []) do
    ticket = "retained-#{System.unique_integer([:positive])}"
    topic = "ticket.#{ticket}.workspace.workspace_lease_retained"
    :ok = Exchange.subscribe(topic)
    parent = self()

    owner =
      spawn(fn ->
        {:ok, lease} = Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry, opts)
        :ok = Ownership.expect_provider(lease, :local)
        if provider, do: :ok = Ownership.track_provider(lease, provider)
        send(parent, {:claimed, lease})

        receive do
          :exit -> :ok
        end
      end)

    receive_barrier({:claimed, lease})

    on_exit(fn ->
      Process.exit(owner, :kill)
      stop_guardian(lease.guardian)
      Store.delete(ticket)
    end)

    send(owner, :exit)
    {ticket, lease, topic}
  end

  defp stop_guardian(guardian) do
    monitor = Process.monitor(guardian)
    Process.exit(guardian, :kill)
    receive_barrier({:DOWN, ^monitor, :process, ^guardian, _})
  end
end
