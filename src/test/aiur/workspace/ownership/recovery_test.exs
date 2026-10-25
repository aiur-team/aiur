defmodule Aiur.Workspace.Ownership.RecoveryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI
  alias Aiur.Workspace.Ownership
  alias Aiur.Workspace.Ownership.{AuditLog, Guardian, HoldStatus, Store}

  test "a local unknown provider auto-releases after a verified reboot when audit persists" do
    ticket = "ownership-reboot-proof-#{System.unique_integer([:positive])}"
    {:ok, boot} = Agent.start_link(fn -> "boot-before" end)
    audit_path = Path.join(Aiur.TestSupport.tmp_root!("workspace-reboot-audit"), "#{ticket}.ndjson")
    audit_fun = &AuditLog.write(&1, path: audit_path)

    boot_id_fun = fn ->
      case Agent.get(boot, & &1) do
        :unavailable -> :unknown
        boot_id -> {:ok, boot_id}
      end
    end

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(boot)
      File.rm(audit_path)
      _ = Store.delete(ticket)
    end)

    assert {:ok, lease} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
               host_boot_id_fun: boot_id_fun,
               audit_fun: audit_fun
             )

    assert :ok = Ownership.expect_provider(lease, :local)
    assert {:ok, %{provider_scope: :local, provider_boot_id: "boot-before", provider: nil} = receipt} = Store.get(ticket)

    Process.exit(lease.guardian, :kill)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)

    assert {:ok, held} =
             Guardian.restore(receipt, Aiur.Workspace.Ownership.Registry,
               host_boot_id_fun: boot_id_fun,
               audit_fun: audit_fun
             )

    assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)

    assert %{generation: generation, proof: :same_boot} =
             HoldStatus.for_ticket(ticket, Aiur.Workspace.Ownership.Registry, Store, boot_id_fun)

    assert generation == lease.generation
    assert {:error, {:workspace_owned, {:ok, %{generation: generation}}}} = Ownership.claim(ticket)
    assert generation == lease.generation

    Process.exit(held.guardian, :kill)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
    Agent.update(boot, fn _ -> :unavailable end)

    assert {:ok, unprobed} =
             Guardian.restore(receipt, Aiur.Workspace.Ownership.Registry,
               host_boot_id_fun: boot_id_fun,
               audit_fun: audit_fun
             )

    assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)

    assert %{proof: :boot_probe_unavailable} =
             HoldStatus.for_ticket(ticket, Aiur.Workspace.Ownership.Registry, Store, boot_id_fun)

    Process.exit(unprobed.guardian, :kill)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
    Agent.update(boot, fn _ -> "boot-after" end)

    assert {:ok, _recovered} =
             Guardian.restore(receipt, Aiur.Workspace.Ownership.Registry,
               host_boot_id_fun: boot_id_fun,
               audit_fun: audit_fun
             )

    assert_eventually(fn -> Ownership.current(ticket) == :none and Store.get(ticket) == {:ok, nil} end)
    assert [audit_line] = File.read!(audit_path) |> String.split("\n", trim: true)
    assert {:ok, audit_record} = Jason.decode(audit_line)
    assert audit_record["action"] == "workspace_hold_auto_release"
    assert audit_record["actor"] == "guardian"
    assert audit_record["ticket"] == ticket
    assert audit_record["generation"] == lease.generation
    assert audit_record["proof"] == "local_host_boot_id_changed"

    assert {:ok, replacement} = Ownership.claim(ticket)
    assert replacement.generation > lease.generation
    assert :ok = Ownership.release(replacement)
  end

  test "remote, legacy, and unprobed unknown-provider receipts remain held after a host reboot" do
    for scope <- [:remote, :legacy, :unprobed] do
      ticket = "ownership-reboot-refusal-#{scope}-#{System.unique_integer([:positive])}"
      initial_boot_id_fun = if scope == :unprobed, do: fn -> :unknown end, else: fn -> {:ok, "boot-before"} end
      {:ok, lease} = Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry, host_boot_id_fun: initial_boot_id_fun)
      assert :ok = Ownership.expect_provider(lease, if(scope == :remote, do: :remote, else: :local))
      assert {:ok, persisted} = Store.get(ticket)

      receipt =
        if scope == :legacy,
          do: Map.drop(persisted, [:provider_scope, :provider_boot_id]),
          else: persisted

      if scope == :legacy, do: assert(:ok = Store.put(ticket, receipt))
      Process.exit(lease.guardian, :kill)
      assert_eventually(fn -> Ownership.current(ticket) == :none end)

      # The changed local boot says nothing about a remote process, a legacy
      # expectation, or an expectation whose original boot could not be read.
      assert {:ok, held} =
               Guardian.restore(receipt, Aiur.Workspace.Ownership.Registry, host_boot_id_fun: fn -> {:ok, "boot-after"} end)

      assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)
      expected_proof = if scope == :remote, do: :remote, else: :not_recorded

      assert %{generation: generation, proof: ^expected_proof} =
               HoldStatus.for_ticket(ticket, Aiur.Workspace.Ownership.Registry, Store, fn -> {:ok, "boot-after"} end)

      assert generation == lease.generation
      assert {:error, {:workspace_owned, {:ok, %{generation: generation}}}} = Ownership.claim(ticket)
      assert generation == lease.generation
      Process.exit(held.guardian, :kill)
      assert_eventually(fn -> Ownership.current(ticket) == :none end)
      assert :ok = Store.delete(ticket)
    end
  end

  test "owner exit after expect_provider creates recoverable hold - regression for Khala#533" do
    ticket = Integer.to_string(System.unique_integer([:positive]))
    {:ok, boot} = Agent.start_link(fn -> "boot-before" end)
    {:ok, telemetry} = Agent.start_link(fn -> [] end)
    {:ok, audit_mode} = Agent.start_link(fn -> :fail_once end)
    audit_path = Path.join(Aiur.TestSupport.tmp_root!("workspace-recovery-audit"), "#{ticket}.ndjson")

    telemetry_fun = fn ownership, boundary, outcome ->
      Agent.update(telemetry, &[{ownership, boundary, outcome} | &1])
    end

    boot_id_fun = fn ->
      case Agent.get(boot, & &1) do
        :unavailable -> :unknown
        boot_id -> {:ok, boot_id}
      end
    end

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(boot)
      Aiur.TestSupport.safe_stop(telemetry)
      Aiur.TestSupport.safe_stop(audit_mode)
      File.rm(audit_path)
      _ = Store.delete(ticket)
    end)

    audit_fun = fn record ->
      case Agent.get_and_update(audit_mode, fn
             :fail_once -> {:fail, :write}
             :write -> {:write, :write}
           end) do
        :fail -> {:error, :disk_full}
        :write -> AuditLog.write(record, path: audit_path)
      end
    end

    # Regression test: Owner exits between expect_provider and track_provider
    # This is the scenario from Khala#533 that left workspaces stuck in reaping
    # Directly claim and expect provider (like the runner would)
    assert {:ok, lease} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
               host_boot_id_fun: boot_id_fun,
               telemetry_fun: telemetry_fun,
               audit_fun: audit_fun
             )

    assert :ok = Ownership.expect_provider(lease, :local)
    assert {:ok, %{provider_expected?: true, provider: nil} = receipt} = Store.get(ticket)

    # Simulate owner death (would trigger guardian reaping)
    Process.exit(lease.guardian, :kill)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)

    # Daemon restarts and restores guardian - it goes into reaping
    assert {:ok, held} =
             Guardian.restore(receipt, Aiur.Workspace.Ownership.Registry,
               host_boot_id_fun: boot_id_fun,
               telemetry_fun: telemetry_fun,
               audit_fun: audit_fun
             )

    assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)

    # Hold status shows :same_boot - provider might still be running
    generation = lease.generation

    assert %{generation: ^generation, proof: :same_boot} =
             HoldStatus.for_ticket(ticket, Aiur.Workspace.Ownership.Registry, Store, boot_id_fun)

    # Workspace is held - cannot redispatch
    assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} = Ownership.claim(ticket)

    # Host reboots (simulated by changing boot ID). Proof is retained until an
    # operator explicitly releases this exact generation.
    Process.exit(held.guardian, :kill)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
    Agent.update(boot, fn _ -> "boot-after" end)
    Agent.update(audit_mode, fn _ -> :fail_once end)

    # Daemon attempts auto-release with new boot proof. A failed audit write
    # must retain the lease so an operator can retry after storage recovers.
    assert {:ok, _recovered} =
             Guardian.restore(receipt, Aiur.Workspace.Ownership.Registry,
               host_boot_id_fun: boot_id_fun,
               telemetry_fun: telemetry_fun,
               audit_fun: audit_fun
             )

    # Guardian.restore/3 replies before the guardian attempts its automatic
    # release, so wait until that attempt has consumed the injected failure.
    # Otherwise the attempt can run after the operator retry below re-arms
    # :fail_once, consume it, and let the operator release succeed.
    assert_eventually(fn -> Agent.get(audit_mode, & &1) == :write end)
    assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)

    assert %{generation: ^generation, proof: :boot_changed_release_pending} =
             HoldStatus.for_ticket(ticket, Aiur.Workspace.Ownership.Registry, Store, boot_id_fun)

    assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} = Ownership.claim(ticket)
    assert {:error, :generation_mismatch} = Ownership.release_if_held_with_exit_proof(ticket, generation + 1)
    assert {:ok, %{phase: :reaping}} = Ownership.current(ticket)

    Agent.update(audit_mode, fn _ -> :fail_once end)
    failed_output = capture_io(fn -> AgentControlCLI.recover_workspace(ticket, generation) end)
    assert failed_output =~ "durable audit write failed"
    assert failed_output =~ "__AIUR_CONTROL_EXIT__:1"
    assert {:ok, %{phase: :reaping}} = Ownership.current(ticket)
    assert {:ok, %{generation: ^generation}} = Store.get(ticket)

    recovery_identifier = "org/repo##{ticket}"
    output = capture_io(fn -> AgentControlCLI.recover_workspace(recovery_identifier, generation) end)
    assert output =~ "released workspace hold for #{recovery_identifier} generation #{generation}"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    assert_eventually(fn -> Ownership.current(ticket) == :none and Store.get(ticket) == {:ok, nil} end)

    assert Enum.any?(Agent.get(telemetry, & &1), fn
             {%{generation: ^generation}, :point, :operator_release_after_provider_exit_proof} -> true
             _ -> false
           end)

    assert [audit_line] = File.read!(audit_path) |> String.split("\n", trim: true)
    assert {:ok, audit_record} = Jason.decode(audit_line)
    assert audit_record["action"] == "workspace_hold_release"
    assert audit_record["ticket"] == ticket
    assert audit_record["generation"] == generation
    assert audit_record["proof"] == "local_host_boot_id_changed"
    assert is_binary(audit_record["actor"])

    # Redispatch can now claim the workspace with a new generation
    assert {:ok, replacement} = Ownership.claim(ticket)
    assert replacement.generation > generation
    assert :ok = Ownership.release(replacement)
  end

  test "operator can check if workspace hold has release proof but cannot force without it" do
    ticket = "ownership-no-release-proof-#{System.unique_integer([:positive])}"
    parent = self()
    {:ok, boot} = Agent.start_link(fn -> "boot-before" end)

    boot_id_fun = fn ->
      case Agent.get(boot, & &1) do
        :unavailable -> :unknown
        boot_id -> {:ok, boot_id}
      end
    end

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(boot)
      _ = Store.delete(ticket)
    end)

    owner =
      spawn(fn ->
        {:ok, lease} = Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry, host_boot_id_fun: boot_id_fun)
        :ok = Ownership.expect_provider(lease, :local)
        send(parent, {:expected, lease})
        Process.sleep(:infinity)
      end)

    owner_monitor = Process.monitor(owner)
    assert_receive {:expected, lease}, 2_000

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 2_000
    assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)

    # Without boot proof, hold status shows :same_boot
    assert %{proof: :same_boot} =
             HoldStatus.for_ticket(ticket, Aiur.Workspace.Ownership.Registry, Store, boot_id_fun)

    # Operator cannot force release without proof
    assert {:error, :cannot_release_without_proof} = Ownership.release_if_held_with_exit_proof(ticket, lease.generation)

    # Workspace remains held
    assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} = Ownership.claim(ticket)
  end

  test "workspace recovery reports a live generation as not held for reaping" do
    ticket = "ownership-live-recovery-#{System.unique_integer([:positive])}"
    assert {:ok, lease} = Ownership.claim(ticket)

    assert :not_held_for_reaping = Ownership.release_if_held_with_exit_proof(ticket, lease.generation)
    assert {:ok, %{generation: generation, phase: :provisioning}} = Ownership.current(ticket)
    assert generation == lease.generation
    assert :ok = Ownership.release(lease)
  end

  test "workspace recovery reports an unmatched ticket as not found, not success" do
    ticket = Integer.to_string(System.unique_integer([:positive]))
    assert :not_found = Ownership.release_if_held_with_exit_proof(ticket, 7)

    output = capture_io(fn -> AgentControlCLI.recover_workspace("org/repo##{ticket}", 7) end)
    assert output =~ "workspace ownership hold not found"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
    refute output =~ "already released"

    hash_identifier_output = capture_io(fn -> AgentControlCLI.recover_workspace("##{ticket}", 7) end)
    assert hash_identifier_output =~ "workspace ownership hold not found"
    assert hash_identifier_output =~ "__AIUR_CONTROL_EXIT__:1"
  end

  test "workspace recovery passes through non-numeric ticket identifiers" do
    output = capture_io(fn -> AgentControlCLI.recover_workspace("ENG-123", 7) end)

    assert output =~ "workspace ownership hold not found"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
    refute output =~ "invalid ticket identifier"
  end

  defp assert_eventually(fun, attempts \\ 40) do
    if fun.() do
      :ok
    else
      assert attempts > 0
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end
end
