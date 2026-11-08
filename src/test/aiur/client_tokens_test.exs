defmodule Aiur.ClientTokensTest do
  use ExUnit.Case, async: false
  import Bitwise

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-client-tokens-#{System.unique_integer([:positive])}")
    path = Path.join(root, "client-tokens.json")
    previous = Application.get_env(:aiur, :client_tokens_path)
    Application.put_env(:aiur, :client_tokens_path, path)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :client_tokens_path, previous), else: Application.delete_env(:aiur, :client_tokens_path)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, path: path}
  end

  test "uses an existing token directory without changing its permissions", %{path: path} do
    directory = Path.dirname(path)
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o755)

    assert {:ok, token} = Aiur.ClientTokens.create("existing-directory")
    assert {:ok, "existing-directory", "write"} = Aiur.ClientTokens.authenticate(token)
    assert (File.stat!(directory).mode &&& 0o777) == 0o755
  end

  test "stores only a hash, lists metadata, authenticates, and revokes", %{path: path} do
    assert {:ok, token} = Aiur.ClientTokens.create("streamdeck", "read")
    assert {:ok, [%{"name" => "streamdeck", "scope" => "read"}]} = Aiur.ClientTokens.list()
    assert {:ok, "streamdeck", "read"} = Aiur.ClientTokens.authenticate(token)
    refute File.read!(path) =~ token
    assert (File.stat!(path).mode &&& 0o777) == 0o600
    assert (File.stat!(Path.dirname(path)).mode &&& 0o777) == 0o700
    assert :ok = Aiur.ClientTokens.revoke("streamdeck")
    assert :error = Aiur.ClientTokens.authenticate(token)
  end

  test "rejects invalid and duplicate token definitions" do
    assert {:error, :invalid_name} = Aiur.ClientTokens.create("../escape")
    assert {:error, :invalid_scope} = Aiur.ClientTokens.create("reader", "admin")
    assert {:ok, _} = Aiur.ClientTokens.create("reader")
    assert {:error, :name_exists} = Aiur.ClientTokens.create("reader")
  end

  test "corrupt token records fail closed" do
    path = Application.fetch_env!(:aiur, :client_tokens_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!([%{"name" => "incomplete"}]))

    assert {:error, :corrupt_store} = Aiur.ClientTokens.list()
    assert :error = Aiur.ClientTokens.authenticate("untrusted-token")
  end

  test "legacy tokens map to categories and category tokens store a derived scope", %{path: path} do
    {:ok, read} = Aiur.ClientTokens.create("old-read", "read")
    {:ok, write} = Aiur.ClientTokens.create("old-write", "write")
    assert {:ok, %{categories: ["read"], peer: nil}} = Aiur.ClientTokens.authenticate_full(read)
    assert {:ok, %{categories: all}} = Aiur.ClientTokens.authenticate_full(write)
    assert Enum.sort(all) == Enum.sort(~w(read message executor agents tickets config))
    refute "trust" in all

    {:ok, peer} = Aiur.ClientTokens.create("peer", "write", peer: "gw-1", categories: ["read", "message"])
    assert {:ok, %{scope: "write", peer: "gw-1", categories: ["read", "message"]}} = Aiur.ClientTokens.authenticate_full(peer)
    {:ok, ro} = Aiur.ClientTokens.create("peer-ro", "write", peer: "gw-1", categories: ["read"])
    assert {:ok, %{scope: "read"}} = Aiur.ClientTokens.authenticate_full(ro)
    assert {:ok, "peer", "write"} = Aiur.ClientTokens.authenticate(peer)
    assert File.read!(path) =~ "gw-1"
  end

  test "rejects trust, unknown categories, empty lists and read scope with write categories" do
    for bad <- [["trust"], ["bogus"], []] do
      assert {:error, :invalid_categories} = Aiur.ClientTokens.create("bad", "write", categories: bad)
    end

    assert {:error, :scope_conflicts_with_categories} = Aiur.ClientTokens.create("bad", "read", categories: ["agents"])
    assert {:error, :invalid_peer} = Aiur.ClientTokens.create("bad", "write", peer: "../x")
  end
end
