defmodule Aiur.ClientTokensTest do
  use ExUnit.Case, async: false
  import Bitwise

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-client-tokens-#{System.unique_integer([:positive])}")
    path = Path.join(root, "client-tokens.json")
    File.mkdir_p!(root)
    File.chmod!(root, 0o755)
    previous = Application.get_env(:aiur, :client_tokens_path)
    Application.put_env(:aiur, :client_tokens_path, path)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :client_tokens_path, previous), else: Application.delete_env(:aiur, :client_tokens_path)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, path: path}
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
end
