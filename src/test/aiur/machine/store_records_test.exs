defmodule Aiur.Machine.StoreRecordsTest do
  use ExUnit.Case, async: false
  alias Aiur.Machine.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "records-#{System.unique_integer([:positive])}")
    old = Application.get_env(:aiur, :machine_state_dir)
    Application.put_env(:aiur, :machine_state_dir, dir)

    on_exit(fn ->
      if old, do: Application.put_env(:aiur, :machine_state_dir, old), else: Application.delete_env(:aiur, :machine_state_dir)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{paths: Store.paths()}
  end

  defp device(id, parent \\ nil), do: %{device_id: id, label: id, platform: "ios", auth_public_key: "public", parent_device_id: parent, paired_at: "2026-01-01T00:00:00Z"}

  test "put then delete a device cascades to its child watch" do
    for row <- [device("phone"), device("watch", "phone"), device("child", "watch"), device("other")], do: assert(:ok = Store.put_device(row))
    assert :ok = Store.delete_device("phone")
    assert {:ok, [%{"device_id" => "other"}]} = Store.devices()
  end

  test "delete_all_devices clears devices and outstanding secrets", %{paths: p} do
    assert :ok = Store.put_device(device("phone"))
    assert :ok = Store.put_pairing_secret("secret", 200, now: 100)
    assert :ok = Store.delete_all_devices()
    assert Store.devices() == {:ok, []}
    assert Jason.decode!(File.read!(p.pairing)) == []
    assert Store.consume_pairing_secret("secret", 100) == {:error, :pair_secret_unknown}
  end

  test "only sha256 of a pairing secret is written", %{paths: p} do
    secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    assert :ok = Store.put_pairing_secret(secret, 200, now: 100)
    bytes = File.read!(p.pairing)
    refute bytes =~ secret
    assert [%{"hash" => hash, "expires_at" => 200, "used" => false}] = Jason.decode!(bytes)
    assert hash == Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
  end

  test "pairing expiry is bounded to ten minutes" do
    assert Store.put_pairing_secret("s", 701, now: 100) == {:error, :invalid_secret_expiry}
    assert Store.put_pairing_secret("s", 100, now: 100) == {:error, :invalid_secret_expiry}
    assert Store.put_pairing_secret("s", 700, now: 100) == :ok
  end

  test "a fourth secret drops the oldest" do
    for secret <- ~w(first second third fourth), do: assert(:ok = Store.put_pairing_secret(secret, 200, now: 100))
    assert Store.consume_pairing_secret("first", 100) == {:error, :pair_secret_unknown}
    for secret <- ~w(second third fourth), do: assert(:ok = Store.consume_pairing_secret(secret, 100))
  end

  test "used expired and unknown secrets return their own errors" do
    assert :ok = Store.put_pairing_secret("used", 200, now: 100)
    assert :ok = Store.put_pairing_secret("expired", 150, now: 100)
    assert :ok = Store.consume_pairing_secret("used", 100)
    assert Store.consume_pairing_secret("used", 200) == {:error, :pair_secret_used}
    assert Store.consume_pairing_secret("expired", 150) == {:error, :pair_secret_expired}
    assert Store.consume_pairing_secret("unknown", 100) == {:error, :pair_secret_unknown}
    assert Store.put_pairing_secret("used", 300, now: 100) == {:error, :pair_secret_exists}
  end

  test "files are 0600 and known instances persist", %{paths: p} do
    assert :ok = Store.put_device(device("phone"))
    assert :ok = Store.put_pairing_secret("secret", 200, now: 100)
    row = %{instance_id: "instance", repository: "repo", project_root_basename: "project", last_seen_at: 100}
    assert :ok = Store.put_known_instances([row])
    assert Store.known_instances() == {:ok, [Jason.decode!(Jason.encode!(row))]}
    for path <- [p.devices, p.pairing, p.known_instances], do: assert(Bitwise.band(File.stat!(path).mode, 0o777) == 0o600)
    assert :ok = Store.put_known_instances([])
    assert Store.known_instances() == {:ok, []}
  end

  test "corrupt devices.json is never overwritten", %{paths: p} do
    assert :ok = Store.check_dir(p.dir)

    for bytes <- ["{broken", "{}", "[{}]", "null"] do
      File.write!(p.devices, bytes)
      File.chmod!(p.devices, 0o600)
      assert Store.devices() == {:error, :store_corrupt}
      assert Store.put_device(device("phone")) == {:error, :store_corrupt}
      assert Store.delete_all_devices() == {:error, :store_corrupt}
      assert File.read!(p.devices) == bytes
    end
  end

  test "corrupt pairing and known instances are never overwritten", %{paths: p} do
    assert :ok = Store.check_dir(p.dir)

    for {path, write} <- [{p.pairing, fn -> Store.put_pairing_secret("s", 200, now: 100) end}, {p.known_instances, fn -> Store.put_known_instances([]) end}] do
      File.write!(path, "[{}]")
      File.chmod!(path, 0o600)
      assert write.() == {:error, :store_corrupt}
      assert File.read!(path) == "[{}]"
    end
  end

  test "token hashes keep at most four and prune expired" do
    assert :ok = Store.put_device(device("phone"))
    for n <- 1..5, do: assert(:ok = Store.add_token_hash("phone", String.duplicate(to_string(n), 64), 200, now: 100))
    assert :ok = Store.add_token_hash("phone", String.duplicate("a", 64), 99, now: 100)
    assert {:ok, [row]} = Store.devices()
    assert Enum.map(row["token_hashes"], & &1["hash"]) == Enum.map(2..5, &String.duplicate(to_string(&1), 64))
    assert :ok = Store.prune_expired_tokens(200)
    assert {:ok, [%{"token_hashes" => []}]} = Store.devices()
    assert Store.add_token_hash("missing", String.duplicate("a", 64), 200) == {:error, :device_unknown}
  end

  test "journal callback runs before the devices rename inside the lock", %{paths: p} do
    assert :ok = Store.put_device(device("old"))
    before = File.read!(p.devices)

    assert_raise RuntimeError, "journal failed", fn ->
      Store.put_device(device("new"),
        journal: fn ->
          assert File.exists?(Path.join(p.dir, "store.lock/owner"))
          assert File.read!(p.devices) == before
          raise "journal failed"
        end
      )
    end

    assert File.read!(p.devices) == before
    refute File.exists?(Path.join(p.dir, "store.lock"))
    assert Store.put_device(device("new"), journal: fn -> {:error, :journal_failed} end) == {:error, :journal_failed}
  end

  test "nested writes reuse the lock and simultaneous consumes have one winner" do
    assert :ok = Store.with_lock(fn -> Store.put_pairing_secret("race", 200, now: 100) end)
    tasks = for _ <- 1..4, do: Task.async(fn -> Store.consume_pairing_secret("race", 100) end)
    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :pair_secret_used})) == 3
  end
end
