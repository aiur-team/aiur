defmodule Aiur.Workspace.Ownership.ProviderTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.Ownership
  alias Aiur.Workspace.Ownership.{Guardian, HoldStatus, Store}

  test "release_and_wait retains an expected provider when containment and cleanup are unavailable" do
    ticket = "ownership-unidentified-provider-#{System.unique_integer([:positive])}"
    assert {:ok, lease} = Ownership.claim(ticket)
    assert :ok = Ownership.expect_provider(lease)

    cleanup = Task.async(fn -> Ownership.release_and_wait(lease) end)

    assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)
    refute Task.yield(cleanup, 100)
    assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} = Ownership.claim(ticket)
    Task.shutdown(cleanup, :brutal_kill)
  end

  test "releases an exact-generation expectation cancelled before provider spawn" do
    ticket = "ownership-cancelled-expectation-#{System.unique_integer([:positive])}"
    assert {:ok, lease} = Ownership.claim(ticket)
    assert :ok = Ownership.expect_provider(lease)
    assert :ok = Ownership.cancel_provider_expectation(lease)
    assert {:ok, %{phase: :released}} = Ownership.release_and_wait(lease)
    assert :none = Ownership.current(ticket)
  end

  test "rejects stale provider registration instead of acknowledging a lost lease" do
    ticket = "ownership-stale-provider-#{System.unique_integer([:positive])}"
    assert {:ok, lease} = Ownership.claim(ticket)

    stale = %{lease | generation: lease.generation + 1}

    assert {:error, :workspace_ownership_lost} = Ownership.activate(stale)
    assert {:error, :workspace_ownership_lost} = Ownership.expect_provider(stale)
    assert {:error, :workspace_ownership_lost} = Ownership.cancel_provider_expectation(stale)
    assert {:error, :workspace_ownership_lost} = Ownership.track_provider(stale, %{root_pid: 42})
    assert {:error, :workspace_ownership_lost} = Ownership.mark_provider_cleanup_unknown(stale)
    assert {:error, :workspace_ownership_lost} = Ownership.mark_provider_cleanup_succeeded(stale)
    assert :ok = Ownership.release(stale)
    assert {:error, :workspace_ownership_lost} = Ownership.release_and_wait(stale)
    assert {:error, :workspace_ownership_lost} = Ownership.track_provider(lease, %{})
    assert {:error, :workspace_ownership_lost} = Ownership.expect_provider(nil)
    assert {:error, :workspace_ownership_lost} = Ownership.track_provider(nil, %{root_pid: 42})

    assert :ok = Ownership.release(lease)
  end

  test "accepts a descendant-only provider snapshot as containment" do
    ticket = "ownership-descendant-only-#{System.unique_integer([:positive])}"
    descendant_pid = System.unique_integer([:positive])
    assert {:ok, lease} = Ownership.claim(ticket)

    assert :ok = Ownership.track_provider(lease, %{descendant_pids: [descendant_pid]})
    assert :ok = Ownership.mark_provider_cleanup_succeeded(lease)
    assert {:ok, %{phase: :released}} = Ownership.release_and_wait(lease)
  end

  # An in-process session (an OpenAI-compatible HTTP agent) has no OS process,
  # group, or remote host. It must be accepted as a valid provider so dispatch
  # is not rejected before the first turn, and the lease must release cleanly
  # on owner death (there is nothing to reap).
  test "accepts an in-process provider and releases cleanly on owner death" do
    ticket = "ownership-in-process-#{System.unique_integer([:positive])}"
    parent = self()

    owner =
      spawn(fn ->
        {:ok, lease} = Ownership.claim(ticket)
        {:ok, active_lease} = Ownership.activate(lease)
        :ok = Ownership.expect_provider(lease)
        :ok = Ownership.track_provider(lease, %{in_process: true})
        send(parent, {:in_process_tracked, active_lease})
        Process.sleep(:infinity)
      end)

    assert_receive {:in_process_tracked, _lease}, 2_000
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 2_000
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
  end

  # The `in_process` marker is session-level, but a provider that later also
  # reports an OS identity must not be released early: the marker's fast path
  # only applies while the provider has nothing to reap. A merged descendant
  # snapshot therefore keeps the lease fail-closed in :reaping like any other
  # OS containment rather than being released through the in-process path.
  test "an in-process provider that later reports descendants is retained, not released early" do
    ticket = "ownership-in-process-descendant-#{System.unique_integer([:positive])}"
    child_pid = System.unique_integer([:positive])
    parent = self()

    owner =
      spawn(fn ->
        {:ok, lease} =
          Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
            process_alive_fun: fn _pid -> true end,
            process_identity_fun: fn ^child_pid -> {:ok, :late_child} end
          )

        :ok = Ownership.track_provider(lease, %{in_process: true})
        :ok = Ownership.track_provider(lease, %{descendant_pids: [child_pid]})
        send(parent, {:in_process_descendant_tracked, lease})
        Process.sleep(:infinity)
      end)

    assert_receive {:in_process_descendant_tracked, lease}, 2_000
    Process.exit(owner, :kill)

    assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)
    assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} = Ownership.claim(ticket)

    Process.exit(lease.guardian, :kill)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
  end

  # A descendant-only provider has no `in_process` marker and must be treated
  # strictly as OS containment: on owner death with nothing proven gone it is
  # retained (fail-closed), never released through the in-process fast path.
  test "a descendant-only provider is not treated as in-process" do
    ticket = "ownership-descendant-not-in-process-#{System.unique_integer([:positive])}"
    descendant_pid = System.unique_integer([:positive])
    parent = self()

    owner =
      spawn(fn ->
        {:ok, lease} =
          Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
            process_alive_fun: fn _pid -> true end,
            process_identity_fun: fn ^descendant_pid -> {:ok, :only_descendant} end
          )

        :ok = Ownership.track_provider(lease, %{descendant_pids: [descendant_pid]})
        send(parent, {:descendant_only_tracked, lease})
        Process.sleep(:infinity)
      end)

    assert_receive {:descendant_only_tracked, lease}, 2_000
    guardian = lease.guardian
    guardian_monitor = Process.monitor(guardian)
    Process.exit(owner, :kill)

    assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)
    assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} = Ownership.claim(ticket)

    Process.exit(guardian, :kill)
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, _reason}, 2_000
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
  end

  test "duplicate and malformed receipt restoration fail closed" do
    ticket = "ownership-restore-fencing-#{System.unique_integer([:positive])}"
    assert {:ok, lease} = Ownership.claim(ticket)
    assert {:ok, receipt} = Store.get(ticket)

    competing_guardian =
      Guardian.start(
        self(),
        ticket,
        System.unique_integer([:positive]),
        Aiur.Workspace.Ownership.Registry,
        []
      )

    assert_receive {
                     :workspace_guardian_claimed,
                     ^competing_guardian,
                     {:error, {:workspace_owned, {:ok, %{generation: competing_generation}}}}
                   },
                   1000

    assert competing_generation == lease.generation

    assert {:error, {:workspace_owned, {:ok, %{generation: generation}}}} =
             Guardian.restore(receipt, Aiur.Workspace.Ownership.Registry, [])

    assert generation == lease.generation

    assert {:error, {:invalid_workspace_receipt, %KeyError{}}} =
             Guardian.restore(%{}, Aiur.Workspace.Ownership.Registry, [])

    assert :ok = Ownership.release(lease)
  end

  test "a restored malformed provider remains retained for reconciliation" do
    ticket = "ownership-malformed-provider-#{System.unique_integer([:positive])}"

    receipt = %{
      ticket: ticket,
      generation: System.unique_integer([:positive]),
      owner_id: "restored-malformed-provider",
      phase: :reaping,
      provider_expected?: true,
      provider: %{},
      provider_cleanup: :unresolved
    }

    assert {:ok, lease} = Guardian.restore(receipt, Aiur.Workspace.Ownership.Registry, [])
    assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)
    # The registry entry is visible before the guardian persists the receipt.
    assert_eventually(fn -> match?({:ok, %{generation: _}}, Store.get(ticket)) end)

    assert %{generation: generation, proof: :not_recorded} =
             HoldStatus.for_ticket(ticket, Aiur.Workspace.Ownership.Registry, Store)

    assert generation == receipt.generation

    Process.exit(lease.guardian, :kill)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
    assert :ok = Store.delete(ticket)
  end

  test "an unknown descendant identity keeps an explicit release fail closed" do
    ticket = "ownership-unknown-descendant-#{System.unique_integer([:positive])}"
    root_pid = System.unique_integer([:positive])
    child_pid = System.unique_integer([:positive])

    assert {:ok, lease} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
               process_alive_fun: fn _pid -> false end,
               process_identity_fun: fn
                 ^root_pid -> :gone
                 ^child_pid -> :unknown
               end
             )

    assert :ok = Ownership.track_provider(lease, %{root_pid: root_pid, descendant_pids: [child_pid]})
    release = Task.async(fn -> Ownership.release_and_wait(lease) end)

    refute Task.yield(release, 50)
    assert {:error, {:workspace_owned, {:ok, _lease}}} = Ownership.claim(ticket)

    Task.shutdown(release, :brutal_kill)
    Process.exit(lease.guardian, :kill)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
    assert :ok = Store.delete(ticket)
  end

  test "a throwing liveness probe and ineffective reaper retain the workspace" do
    ticket = "ownership-probe-failure-#{System.unique_integer([:positive])}"
    root_pid = System.unique_integer([:positive])
    parent = self()

    assert {:ok, lease} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
               root_alive_fun: fn ^root_pid -> raise "probe failed" end,
               process_identity_fun: fn ^root_pid -> {:ok, :original} end,
               root_reap_fun: fn ^root_pid, {:known, :original} ->
                 send(parent, :ineffective_root_reap)
                 raise "reaper failed"
               end
             )

    assert :ok = Ownership.track_provider(lease, %{root_pid: root_pid})
    release = Task.async(fn -> Ownership.release_and_wait(lease) end)

    assert_receive :ineffective_root_reap, 2_000
    assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)
    refute Task.yield(release, 50)

    Task.shutdown(release, :brutal_kill)
    Process.exit(lease.guardian, :kill)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
    assert :ok = Store.delete(ticket)
  end

  test "an unknown root identity keeps release blocked without signaling" do
    ticket = "ownership-unknown-root-#{System.unique_integer([:positive])}"
    root_pid = System.unique_integer([:positive])
    parent = self()

    assert {:ok, lease} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
               root_alive_fun: fn ^root_pid -> false end,
               process_identity_fun: fn ^root_pid -> :unknown end,
               root_reap_fun: fn ^root_pid -> send(parent, :unexpected_unknown_root_reap) end
             )

    assert :ok = Ownership.track_provider(lease, %{root_pid: root_pid})
    release = Task.async(fn -> Ownership.release_and_wait(lease) end)

    refute Task.yield(release, 50)
    refute_receive :unexpected_unknown_root_reap, 0
    assert {:error, {:workspace_owned, {:ok, _lease}}} = Ownership.claim(ticket)

    Task.shutdown(release, :brutal_kill)
    Process.exit(lease.guardian, :kill)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
    assert :ok = Store.delete(ticket)
  end

  test "remote ownership remains fail-closed when its owner dies" do
    ticket = "ownership-remote-recovery-#{System.unique_integer([:positive])}"
    parent = self()

    owner =
      spawn(fn ->
        {:ok, lease} =
          Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry)

        :ok = Ownership.track_provider(lease, %{remote: true})
        send(parent, {:remote_provider_tracked, lease})
        Process.sleep(:infinity)
      end)

    assert_receive {:remote_provider_tracked, _lease}, 2_000
    Process.exit(owner, :kill)

    assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)
    Process.sleep(150)
    assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} = Ownership.claim(ticket)
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
