defmodule Aiur.Machine.StoreIdentityTest do
  use ExUnit.Case, async: false
  alias Aiur.Identity.Store, as: IdentityStore
  alias Aiur.Machine.Store

  setup do
    root = Path.join(System.tmp_dir!(), "machine-store-#{System.unique_integer([:positive])}")
    previous = System.get_env("AIUR_BG_STATE_DIR")
    override = Application.get_env(:aiur, :machine_state_dir)
    System.put_env("AIUR_BG_STATE_DIR", root)
    Application.delete_env(:aiur, :machine_state_dir)

    on_exit(fn ->
      if previous, do: System.put_env("AIUR_BG_STATE_DIR", previous), else: System.delete_env("AIUR_BG_STATE_DIR")
      if override, do: Application.put_env(:aiur, :machine_state_dir, override), else: Application.delete_env(:aiur, :machine_state_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root, paths: Store.paths()}
  end

  test "paths match boot identity and its override", %{root: root, paths: p} do
    assert p.dir == Path.join(root, "machine")

    for {key, name} <- [identity: "identity.json", store: "store.json", machine_key: "machine_key", machine_public_key: "machine_key.pub"] do
      assert p[key] == Path.join(p.dir, name)
    end

    Application.put_env(:aiur, :machine_state_dir, Path.join(root, "override"))
    assert Store.paths().dir == IdentityStore.dir()
    assert Store.paths().dir == Path.join(root, "override")
  end

  test "reads MP-R1 identity without rewriting", %{paths: p} do
    identity = %{machine_id: Base.encode32(:crypto.strong_rand_bytes(16), case: :lower, padding: false), machine_label: "workstation", created_at: DateTime.to_iso8601(DateTime.utc_now())}
    assert :ok = IdentityStore.create(p.dir, Map.put(identity, :schema_version, 1))
    before = File.read!(p.identity)
    assert Store.identity() == {:ok, identity}
    assert identity.machine_label == "workstation"
    assert File.read!(p.identity) == before
  end

  test "missing identity creates nothing", %{root: root, paths: p} do
    assert Store.identity() == {:error, :identity_unavailable, :missing}
    refute File.exists?(root)
    File.mkdir_p!(p.dir)
    File.write!(Path.join(p.dir, "sentinel"), "preserve")
    before = File.ls!(p.dir)
    assert Store.identity() == {:error, :identity_unavailable, :missing}
    assert File.ls!(p.dir) == before
  end

  test "corrupt identity is preserved and invalid fields fail closed", %{paths: p} do
    File.mkdir_p!(p.dir)
    valid = %{"schema_version" => 1, "machine_id" => String.duplicate("a", 26), "machine_label" => "test", "created_at" => DateTime.to_iso8601(DateTime.utc_now())}

    for bytes <- ["{broken", Jason.encode!(%{}), Jason.encode!(Map.put(valid, "machine_id", "invalid")), Jason.encode!(Map.put(valid, "schema_version", 2))] do
      File.write!(p.identity, bytes)
      assert Store.identity() == {:error, :identity_unavailable, :corrupt}
      assert File.read!(p.identity) == bytes
    end
  end

  test "unreadable identity and symlink are refused", %{root: root, paths: p} do
    File.mkdir_p!(p.dir)
    File.write!(p.identity, "secret")
    File.chmod!(p.identity, 0o000)
    assert Store.identity() == {:error, :identity_unavailable, :unreadable}
    File.chmod!(p.identity, 0o600)
    File.rm!(p.identity)
    File.write!(Path.join(root, "target"), "secret")
    File.ln_s!(Path.join(root, "target"), p.identity)
    assert Store.identity() == {:error, :identity_unavailable, :unreadable}
  end

  test "initialization creates private keys and store and is idempotent", %{paths: p} do
    assert {:ok, pub} = Store.init_machine_key()
    assert byte_size(pub) == 32
    seed = File.read!(p.machine_key)
    assert byte_size(seed) == 32
    assert File.read!(p.machine_public_key) == pub
    assert Jason.decode!(File.read!(p.store)) == %{"schema" => 1}
    assert Bitwise.band(File.stat!(p.dir).mode, 0o777) == 0o700
    for path <- [p.machine_key, p.machine_public_key, p.store], do: assert(Bitwise.band(File.stat!(path).mode, 0o777) == 0o600)
    assert Store.init_machine_key() == {:ok, pub}
    assert Store.machine_public_key() == {:ok, pub}
    assert File.read!(p.machine_key) == seed
    refute File.exists?(p.identity)
  end

  test "public key is recovered from seed", %{paths: p} do
    assert {:ok, pub} = Store.init_machine_key()
    seed = File.read!(p.machine_key)
    File.rm!(p.machine_public_key)
    assert Store.init_machine_key() == {:ok, pub}
    assert File.read!(p.machine_public_key) == pub
    assert File.read!(p.machine_key) == seed
  end

  test "public key without seed is refused", %{paths: p} do
    assert {:ok, pub} = Store.init_machine_key()
    File.rm!(p.machine_key)
    assert Store.init_machine_key() == {:error, :machine_key_missing}
    assert Store.machine_public_key() == {:error, :machine_key_missing}
    assert File.read!(p.machine_public_key) == pub
    refute File.exists?(p.machine_key)
  end

  test "signature verifies but flipped bytes and invalid signatures fail", %{paths: p} do
    assert {:ok, _pub} = Store.init_machine_key()
    signature = :crypto.sign(:eddsa, :none, "message", [File.read!(p.machine_key), :ed25519])
    assert Store.verify("message", signature)
    refute Store.verify("messagf", signature)
    refute Store.verify("message", <<0::512>>)
    refute Store.verify("message", "short")
    File.rm!(p.machine_key)
    refute Store.verify("message", signature)
  end

  test "foreign owner is refused before chmod and own directory tightened", %{paths: p} do
    File.mkdir_p!(p.dir)
    File.chmod!(p.dir, 0o755)
    stat = File.lstat!(p.dir)
    assert Store.check_dir(p.dir, stat_fun: fn _ -> {:ok, %{stat | uid: stat.uid + 1}} end) == {:error, :bad_owner}
    assert Bitwise.band(File.stat!(p.dir).mode, 0o777) == 0o755
    assert Store.check_dir(p.dir) == :ok
    assert Bitwise.band(File.stat!(p.dir).mode, 0o777) == 0o700
  end

  test "unreadable files, widened modes and symlinks are refused", %{paths: p} do
    assert {:ok, _pub} = Store.init_machine_key()

    for path <- [p.machine_key, p.machine_public_key, p.store] do
      File.chmod!(path, 0o000)
      assert Store.init_machine_key() == {:error, :unreadable}
      File.chmod!(path, 0o644)
      assert Store.init_machine_key() == {:error, :bad_permissions}
      File.chmod!(path, 0o600)
    end

    File.rm!(p.machine_public_key)
    File.ln_s!(p.machine_key, p.machine_public_key)
    assert Store.init_machine_key() == {:error, :unsafe_path}
  end

  test "corrupt keys and unknown schemas fail closed", %{paths: p} do
    assert {:ok, _pub} = Store.init_machine_key()
    seed = File.read!(p.machine_key)
    File.write!(p.machine_key, "bad")
    assert Store.init_machine_key() == {:error, :machine_key_corrupt}
    assert Store.machine_public_key() == {:error, :machine_key_corrupt}
    File.write!(p.machine_key, seed)
    File.write!(p.machine_public_key, <<0::256>>)
    assert Store.init_machine_key() == {:error, :machine_key_mismatch}
    assert Store.machine_public_key() == {:error, :machine_key_mismatch}
    File.write!(p.store, ~s({"schema":2}))
    assert Store.init_machine_key() == {:error, :store_schema_unsupported}
    assert File.read!(p.store) == ~s({"schema":2})
    File.write!(p.store, "bad")
    assert Store.init_machine_key() == {:error, :store_corrupt}
  end

  test "no export returns seed and no untagged signer exists", %{paths: p} do
    assert {:ok, _pub} = Store.init_machine_key()
    seed = File.read!(p.machine_key)
    exports = Store.__info__(:functions)
    refute {:machine_key, 0} in exports
    refute {:sign, 1} in exports

    for {name, 0} <- exports do
      result = apply(Store, name, [])
      refute result == seed
      refute result == {:ok, seed}
    end
  end
end
