defmodule Aiur.Gateway.InvitesTest do
  use ExUnit.Case, async: false

  alias Aiur.Gateway.Invites

  setup do
    path = Path.join(System.tmp_dir!(), "invites-#{System.unique_integer([:positive])}/gateway-invites.json")
    Application.put_env(:aiur, :gateway_invites_path, path)

    on_exit(fn ->
      Application.delete_env(:aiur, :gateway_invites_path)
      Aiur.TestCleanup.rm_rf!(Path.dirname(path))
    end)

    %{path: path}
  end

  test "create stores only the secret's hash, in a 0600 file", %{path: path} do
    {:ok, invite} = Invites.create(["read"], 600, 1_000)
    text = File.read!(path)
    refute text =~ invite.secret
    assert invite.exp == 1_600
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
  end

  test "redeem burns the invite once and runs the writes under it" do
    {:ok, %{id: id, secret: secret}} = Invites.create(["read", "message"], 600, 1_000)
    assert {:ok, :wrote} = Invites.redeem(id, secret, 1_100, fn grants -> assert grants == ["read", "message"] && {:ok, :wrote} end)
    assert {:error, :used} = Invites.redeem(id, secret, 1_101, fn _ -> flunk("must not run") end)
  end

  test "a wrong secret and an unknown id are the same error and burn nothing" do
    {:ok, %{id: id, secret: secret}} = Invites.create(["read"], 600, 1_000)
    assert {:error, :invalid_invite} = Invites.redeem(id, secret <> "x", 1_100, fn _ -> flunk("must not run") end)
    assert {:error, :invalid_invite} = Invites.redeem("deadbeef", secret, 1_100, fn _ -> flunk("must not run") end)
    assert {:ok, :ok} = Invites.redeem(id, secret, 1_100, fn _ -> {:ok, :ok} end)
  end

  test "an expired invite is refused and the writes never run" do
    {:ok, %{id: id, secret: secret}} = Invites.create(["read"], 600, 1_000)
    assert {:error, :expired} = Invites.redeem(id, secret, 1_600, fn _ -> flunk("must not run") end)
  end

  test "a failed write leaves the invite unused" do
    {:ok, %{id: id, secret: secret}} = Invites.create(["read"], 600, 1_000)
    assert {:error, :duplicate_peer} = Invites.redeem(id, secret, 1_100, fn _ -> {:error, :duplicate_peer} end)
    assert {:ok, :ok} = Invites.redeem(id, secret, 1_101, fn _ -> {:ok, :ok} end)
  end

  test "concurrent redemptions of one code succeed exactly once" do
    {:ok, %{id: id, secret: secret}} = Invites.create(["read"], 600, 1_000)

    results =
      1..8
      |> Task.async_stream(fn _ -> Invites.redeem(id, secret, 1_100, fn _ -> {:ok, :won} end) end, max_concurrency: 8)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == {:ok, :won})) == 1
    assert Enum.count(results, &(&1 == {:error, :used})) == 7
  end

  test "open? is true only while an unused unexpired invite exists" do
    refute Invites.open?(1_000)
    {:ok, %{id: id, secret: secret}} = Invites.create(["read"], 600, 1_000)
    assert Invites.open?(1_100)
    refute Invites.open?(1_600)
    {:ok, _} = Invites.redeem(id, secret, 1_100, fn _ -> {:ok, :ok} end)
    refute Invites.open?(1_101)
  end

  test "ttl outside 1s..24h is refused" do
    assert {:error, :invalid_ttl} = Invites.create(["read"], 0)
    assert {:error, :invalid_ttl} = Invites.create(["read"], 86_401)
  end
end
