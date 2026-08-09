defmodule Aiur.Workspace.OwnershipReconcilerTest do
  use ExUnit.Case, async: false

  alias Aiur.Workspace.Ownership
  alias Aiur.Workspace.Ownership.{Reconciler, Store}

  test "a persisted unresolved group is reaped before a replacement lease after restart" do
    root = Path.join(System.tmp_dir!(), "ownership-restart-#{System.unique_integer([:positive])}")
    ticket = "ownership-restart-ticket-#{System.unique_integer([:positive])}"
    process_group_id = System.unique_integer([:positive])
    parent = self()
    store_name = Module.concat(__MODULE__, :FirstStore)
    registry_name = Module.concat(__MODULE__, :FirstRegistry)

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, first_store} = start_supervised({Store, name: store_name, state_dir: root, sync_fun: fn -> :ok end})
    {:ok, _first_registry} = start_supervised({Registry, keys: :unique, name: registry_name})

    assert {:ok, lease} =
             Ownership.claim(ticket, registry_name,
               store: first_store,
               process_identity_fun: fn ^process_group_id -> {:ok, :original} end
             )

    assert :ok = Ownership.expect_provider(lease)
    assert :ok = Ownership.track_process_group(lease, process_group_id)
    Process.exit(lease.guardian, :kill)
    assert_eventually(fn -> Ownership.current(ticket, registry_name) == :none end)

    stop_supervised(registry_name)
    stop_supervised(Store)

    second_store_name = Module.concat(__MODULE__, :SecondStore)
    second_registry_name = Module.concat(__MODULE__, :SecondRegistry)
    reconciler_name = Module.concat(__MODULE__, :Reconciler)
    {:ok, alive} = Agent.start_link(fn -> true end)

    on_exit(fn -> Aiur.TestSupport.safe_stop(alive) end)

    {:ok, second_store} =
      start_supervised({Store, name: second_store_name, state_dir: root, sync_fun: fn -> :ok end})

    {:ok, _second_registry} = start_supervised({Registry, keys: :unique, name: second_registry_name})

    assert {:ok, _reconciler} =
             start_supervised(
               {Reconciler,
                name: reconciler_name,
                store: second_store,
                registry: second_registry_name,
                guardian_opts: [
                  group_alive_fun: fn ^process_group_id -> Agent.get(alive, & &1) end,
                  process_identity_fun: fn ^process_group_id -> {:ok, :original} end,
                  reap_fun: fn ^process_group_id, {:known, :original} ->
                    send(parent, :recovered_group_reap)
                    Agent.update(alive, fn _ -> false end)
                    {:ok, :reaped}
                  end
                ]}
             )

    assert_receive :recovered_group_reap, 2_000

    assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} =
             Ownership.claim(ticket, second_registry_name, store: second_store)

    assert_eventually(fn -> Ownership.current(ticket, second_registry_name) == :none end)
    assert {:ok, replacement} = Ownership.claim(ticket, second_registry_name, store: second_store)
    assert :ok = Ownership.release(replacement, second_registry_name)
  end

  test "a corrupt receipt store is quarantined and re-initialized instead of blocking startup" do
    root = Path.join(System.tmp_dir!(), "ownership-corrupt-#{System.unique_integer([:positive])}")
    store_name = Module.concat(__MODULE__, :CorruptStore)
    path = Path.join(root, "workspace-ownership.receipts")

    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(root)
    corrupt = :erlang.term_to_binary(:wrong_format)
    File.write!(path, corrupt)

    {:ok, store} = Store.start_link(name: store_name, state_dir: root, sync_fun: fn -> :ok end)

    assert {:ok, %{}} = Store.all(store)

    # the corrupt bytes are preserved for forensics under a .corrupt-* sibling
    assert [quarantined] = Path.wildcard(path <> ".corrupt-*")
    assert File.read!(quarantined) == corrupt

    # and the live store is a fresh, writable store again
    assert :ok = Store.put("ticket", %{phase: :active}, store)
    assert {:ok, %{"ticket" => %{phase: :active}}} = Store.all(store)
  end

  test "a v1 receipt reloads in a fresh BEAM before receipt atoms are loaded" do
    root = Path.join(System.tmp_dir!(), "ownership-fresh-beam-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    writer = """
    root = System.fetch_env!("RECEIPT_DIR")
    File.mkdir_p!(root)

    receipts = %{
      "fresh-beam-ticket" => %{
        ticket: "fresh-beam-ticket",
        generation: 42,
        owner_id: "workspace:42",
        phase: :active,
        provider_expected?: true,
        provider: %{
          process_group_id: 12_345,
          root_pid: 12_346,
          descendant_pids: [12_347],
          remote: false,
          process_identities: %{
            {:group, 12_345} => {:known, {:procfs_birth_and_session, "100", "200"}},
            {:root, 12_346} => {:known, {:ps_birth_and_session, "Mon Jan 1 00:00:00 2026 200"}},
            {:process, 12_347} => :unknown
          }
        },
        provider_cleanup: :unresolved
      }
    }

    contents = :erlang.term_to_binary({:aiur_workspace_ownership_receipts, 1, receipts})
    File.write!(Path.join(root, "workspace-ownership.receipts"), contents)
    """

    assert {_output, 0} = fresh_beam(writer, root)

    reader = """
    root = System.fetch_env!("RECEIPT_DIR")

    try do
      String.to_existing_atom("procfs_birth_and_session")
      raise "receipt atom was unexpectedly primed"
    rescue
      ArgumentError -> :ok
    end

    store_module = Module.concat(["Aiur", "Workspace", "Ownership", "Store"])

    {:ok, store} =
      apply(store_module, :start_link, [
        [
          name: nil,
          state_dir: root,
          sync_fun: fn -> :ok end
        ]
      ])

    {:ok, receipts} = apply(store_module, :all, [store])
    true = map_size(receipts) == 1
    IO.puts("receipt-loaded")
    """

    assert {output, 0} = fresh_beam(reader, root, project_code?: true)
    assert output =~ "receipt-loaded"
  end

  test "malformed bytes are quarantined and re-initialized" do
    root = Path.join(System.tmp_dir!(), "ownership-invalid-#{System.unique_integer([:positive])}")
    path = Path.join(root, "workspace-ownership.receipts")

    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(root)
    File.write!(path, <<131, 104>>)

    {:ok, store} = Store.start_link(name: nil, state_dir: root, sync_fun: fn -> :ok end)
    assert {:ok, %{}} = Store.all(store)
    assert [malformed_quarantined] = Path.wildcard(path <> ".corrupt-*")
    assert File.read!(malformed_quarantined) == <<131, 104>>
  end

  test "a newer-version receipts file fails closed instead of being wiped" do
    root = Path.join(System.tmp_dir!(), "ownership-newer-version-#{System.unique_integer([:positive])}")
    path = Path.join(root, "workspace-ownership.receipts")

    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(root)

    # A validly-encoded file written by a hypothetical v2 store: decodes
    # cleanly, carries live receipts, but uses a version we cannot read.
    newer_version =
      :erlang.term_to_binary({:aiur_workspace_ownership_receipts, 2, %{"live-ticket" => %{phase: :active}}})

    File.write!(path, newer_version)

    # The store refuses to boot against a file it cannot decode rather than
    # silently re-initializing empty on a downgrade. Trap exits: the linked
    # store process exits non-normally when init fails.
    Process.flag(:trap_exit, true)

    assert {:error, {:workspace_ownership_store_unavailable, {:unsupported_receipt_version, 2}}} =
             Store.start_link(name: nil, state_dir: root, sync_fun: fn -> :ok end)

    # The file is untouched: not wiped, and no forensic archive was created.
    assert File.read!(path) == newer_version
    assert Path.wildcard(path <> ".corrupt-*") == []
  end

  test "a newer-version receipts file carrying an unknown atom fails closed instead of being wiped" do
    root =
      Path.join(
        System.tmp_dir!(),
        "ownership-newer-version-new-atom-#{System.unique_integer([:positive])}"
      )

    path = Path.join(root, "workspace-ownership.receipts")

    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(root)

    # Build the v2 file in a separate BEAM so the receipts body carries an atom
    # this test VM has never loaded. A `:safe` decode refuses to create that
    # atom, which used to fold the whole file into the corruption path and
    # quarantine + re-initialize empty — silently wiping live ownership data on
    # a downgrade. The store must instead read the version from the outer header
    # and fail closed.
    build_code = """
    root = System.fetch_env!("RECEIPT_DIR")
    new_phase_atom = String.to_atom("phase_new_#{System.unique_integer([:positive])}")
    receipts = %{"live-ticket" => %{phase: new_phase_atom}}
    contents = :erlang.term_to_binary({:aiur_workspace_ownership_receipts, 2, receipts})
    File.write!(Path.join(root, "workspace-ownership.receipts"), contents)
    IO.puts("v2-with-new-atom-written")
    """

    assert {output, 0} = fresh_beam(build_code, root)
    assert output =~ "v2-with-new-atom-written"

    # The store refuses to boot against a newer-version file even though its
    # body could not be decoded here: the unknown atom is intact live data, not
    # corruption.
    Process.flag(:trap_exit, true)

    assert {:error, {:workspace_ownership_store_unavailable, {:unsupported_receipt_version, 2}}} =
             Store.start_link(name: nil, state_dir: root, sync_fun: fn -> :ok end)

    # The file is untouched: not wiped, and no forensic archive was created.
    assert {:ok, written} = File.read(path)

    assert {:aiur_workspace_ownership_receipts, 2, %{"live-ticket" => %{phase: phase_atom}}} =
             :erlang.binary_to_term(written)

    assert phase_atom |> Atom.to_string() =~ "phase_new_"
    assert Path.wildcard(path <> ".corrupt-*") == []
  end

  test "receipt operations report store loss instead of crashing callers" do
    root = Path.join(System.tmp_dir!(), "ownership-store-loss-#{System.unique_integer([:positive])}")
    store_name = Module.concat(__MODULE__, :StoppedStore)

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, store} = Store.start_link(name: store_name, state_dir: root, sync_fun: fn -> :ok end)
    assert :ok = Store.delete("missing-ticket", store)
    :ok = GenServer.stop(store)

    assert {:error, {:store_unavailable, _reason}} = Store.put("ticket", %{phase: :active}, store)
    assert {:error, {:store_unavailable, _reason}} = Store.delete("ticket", store)
    assert {:error, {:store_unavailable, _reason}} = Store.get("ticket", store)
    assert {:error, {:store_unavailable, _reason}} = Store.all(store)
  end

  test "a claim is rejected when its ownership receipt cannot be made durable" do
    root = Path.join(System.tmp_dir!(), "ownership-sync-failure-#{System.unique_integer([:positive])}")
    ticket = "ownership-sync-failure-ticket-#{System.unique_integer([:positive])}"
    store_name = Module.concat(__MODULE__, :FailingStore)
    {:ok, sync_calls} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      File.rm_rf(root)
      Aiur.TestSupport.safe_stop(sync_calls)
    end)

    sync_fun = fn ->
      Agent.get_and_update(sync_calls, fn
        0 -> {:ok, 1}
        count -> {{:error, :disk_full}, count + 1}
      end)
    end

    {:ok, store} = Store.start_link(name: store_name, state_dir: root, sync_fun: sync_fun)

    assert {:error, {:workspace_ownership_unavailable, {:persist_failed, :disk_full}}} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry, store: store)

    assert :none = Ownership.current(ticket)
    assert {:ok, %{}} = Store.all(store)
  end

  defp assert_eventually(fun, attempts \\ 80) do
    if fun.() do
      :ok
    else
      assert attempts > 0
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp fresh_beam(code, root, opts \\ []) do
    executable = System.find_executable("elixir") || raise "elixir executable not found"
    timeout = System.find_executable("timeout") || raise "timeout executable not found"

    code_paths =
      if Keyword.get(opts, :project_code?, false) do
        ["-pa", Application.app_dir(:aiur, "ebin")]
      else
        []
      end

    System.cmd(timeout, ["15", executable] ++ code_paths ++ ["-e", code],
      env: [{"RECEIPT_DIR", root}, {"ERL_FLAGS", "+S 1:1"}],
      stderr_to_stdout: true
    )
  end
end
