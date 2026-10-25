defmodule Aiur.Workspace.Ownership.AdoptionTest do
  use ExUnit.Case, async: true

  alias Aiur.Handoff.Record
  alias Aiur.Workspace.{HostLock, Ownership}
  alias Aiur.Workspace.Ownership.{Adoption, Reconciler, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "ownership-adoption-#{System.unique_integer([:positive])}")
    registry = start_supervised!({Registry, keys: :unique, name: __MODULE__.Registry})
    store = start_supervised!({Store, state_dir: dir, name: __MODULE__.Store})
    workspace = Path.join(dir, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    {:ok, dir: dir, workspace: workspace, opts: [registry: __MODULE__.Registry, store: store], registry: registry, store: store}
  end

  test "adopts an active caller-owned lease while preserving workspace contents and provider receipt", ctx do
    marker = Path.join(ctx.workspace, "unchanged")
    File.write!(marker, "keep this workspace")
    receipt = %{ticket: "3844", generation: 999_999, owner_id: "old", phase: :active, provider: %{in_process: true}, provider_expected?: true}
    assert :ok = Store.put("3844", receipt, ctx.store)
    assert {:ok, lease} = Adoption.adopt("3844", ctx.workspace, ctx.opts)
    assert lease.phase == :active
    assert lease.generation != receipt.generation
    assert {:ok, %{owner: owner}} = Ownership.holder(lease, __MODULE__.Registry)
    assert owner == self()
    assert File.read!(marker) == "keep this workspace"
    assert {:ok, saved} = Store.get("3844", ctx.store)
    assert saved.provider == receipt.provider
    assert saved.host_lock.workspace == ctx.workspace
    assert {:error, {:workspace_owned, {:ok, ^lease}}} = Adoption.adopt("3844", ctx.workspace, ctx.opts)
    assert :ok = Ownership.release(lease)
  end

  test "reclaims a dead daemon lock and rejects a live daemon lock", ctx do
    assert {:ok, _old} = HostLock.acquire(ctx.workspace, "3844", os_pid: 100)
    opts = Keyword.put(ctx.opts, :host_lock_opts, alive_fun: fn 100 -> false end)
    assert {:ok, lease} = Adoption.adopt("3844", ctx.workspace, opts)
    assert {:ok, holder} = HostLock.holder(ctx.workspace)
    assert holder.os_pid != 100
    assert :ok = Ownership.release(lease)

    assert {:ok, lock} = HostLock.acquire(ctx.workspace, "another", os_pid: 101)
    assert {:error, {:workspace_locked, %{os_pid: 101}}} = Adoption.adopt("3844", ctx.workspace, Keyword.put(ctx.opts, :host_lock_opts, alive_fun: fn _ -> true end))
    assert :ok = HostLock.release(lock)
  end

  test "same-VM app restart reuses only the host lock named by the prior receipt", ctx do
    assert {:ok, lock} = HostLock.acquire(ctx.workspace, "3844")
    receipt = %{ticket: "3844", generation: 1, owner_id: "old", phase: :active, host_lock: lock}
    assert :ok = Store.put("3844", receipt, ctx.store)
    opts = Keyword.merge(ctx.opts, issue_id: "issue-id", orchestrator: self())
    assert {:ok, lease} = Adoption.adopt("3844", ctx.workspace, opts)
    assert {:ok, %{owner: owner, holder: holder}} = Ownership.holder(lease, __MODULE__.Registry)
    assert owner == self()
    assert holder.issue_id == "issue-id"
    assert holder.update_recipient == self()
    assert :ok = Ownership.release(lease)

    assert {:ok, other_lock} = HostLock.acquire(ctx.workspace, "3844")
    assert :ok = Store.put("3844", receipt, ctx.store)
    assert {:error, {:workspace_locked, _}} = Adoption.adopt("3844", ctx.workspace, opts)
    assert :ok = HostLock.release(other_lock)
  end

  test "missing workspace creates no lease", ctx do
    assert {:error, :workspace_missing} = Adoption.adopt("3844", Path.join(ctx.dir, "missing"), ctx.opts)
    assert :none = Ownership.current("3844", __MODULE__.Registry)
    assert {:ok, nil} = Store.get("3844", ctx.store)
  end

  test "startup reconciliation leaves a fresh handoff receipt for adoption", ctx do
    receipt = %{ticket: "3844", generation: 1, owner_id: "old", phase: :active}
    assert :ok = Store.put("3844", receipt, ctx.store)

    record = %{
      "handoff_schema" => 1,
      "handoff_id" => "test",
      "written_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "from_version" => "test",
      "generation" => 1,
      "config_fingerprint" => "hash",
      "agents" => [%{"identifier" => "3844"}]
    }

    assert :ok = Record.write(record, dir: ctx.dir)
    start_supervised!({Reconciler, name: __MODULE__.Reconciler, store: ctx.store, registry: __MODULE__.Registry, handoff_opts: [dir: ctx.dir]})
    assert :none = Ownership.current("3844", __MODULE__.Registry)
    assert {:ok, ^receipt} = Store.get("3844", ctx.store)
    assert {:ok, lease} = Adoption.adopt("3844", ctx.workspace, ctx.opts)
    assert :ok = Ownership.release(lease)
  end
end
