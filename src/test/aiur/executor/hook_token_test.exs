defmodule Aiur.Executor.HookTokenTest do
  use ExUnit.Case, async: false
  alias Aiur.Executor.HookToken

  setup do
    root = Aiur.TestSupport.tmp_root!("executor-hook-token")
    previous = Application.fetch_env(:aiur, :executor_state_dir)
    key = System.get_env("AIUR_INSTANCE_KEY")
    Application.put_env(:aiur, :executor_state_dir, root)
    System.put_env("AIUR_INSTANCE_KEY", "hook-test")

    on_exit(fn ->
      if previous == :error, do: Application.delete_env(:aiur, :executor_state_dir), else: Application.put_env(:aiur, :executor_state_dir, elem(previous, 1))
      if key, do: System.put_env("AIUR_INSTANCE_KEY", key), else: System.delete_env("AIUR_INSTANCE_KEY")
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root}
  end

  test "ensure creates private stable files and repairs the curl header", %{root: root} do
    assert {:error, :enoent} = HookToken.read()
    assert :ok = HookToken.ensure()
    assert {:ok, token} = HookToken.read()
    assert byte_size(Base.url_decode64!(token, padding: false)) == 32
    assert File.read!(HookToken.headers_path()) == "Authorization: Bearer #{token}\n"
    assert Bitwise.band(File.stat!(root).mode, 0o777) == 0o700
    for path <- [HookToken.path(), HookToken.headers_path()], do: assert(Bitwise.band(File.stat!(path).mode, 0o777) == 0o600)
    File.write!(HookToken.headers_path(), "broken")
    assert :ok = HookToken.ensure()
    assert HookToken.read() == {:ok, token}
    assert File.read!(HookToken.headers_path()) == "Authorization: Bearer #{token}\n"
  end

  test "rotate revokes the old token and replaces the header" do
    :ok = HookToken.ensure()
    {:ok, old} = HookToken.read()
    assert :ok = HookToken.rotate()
    assert {:ok, fresh} = HookToken.read()
    refute old == fresh
    assert File.read!(HookToken.headers_path()) == "Authorization: Bearer #{fresh}\n"
    assert Bitwise.band(File.stat!(HookToken.path()).mode, 0o777) == 0o600
  end

  test "concurrent ensure preserves one credential and corrupt state fails closed" do
    assert Enum.all?(1..8 |> Task.async_stream(fn _ -> HookToken.ensure() end) |> Enum.to_list(), &(&1 == {:ok, :ok}))
    {:ok, token} = HookToken.read()
    assert File.read!(HookToken.headers_path()) == "Authorization: Bearer #{token}\n"
    File.write!(HookToken.path(), "bad\nheader")
    assert HookToken.ensure() == {:error, :invalid_token}
    assert File.read!(HookToken.path()) == "bad\nheader"
  end

  test "instance identities are separate and cannot escape the state directory", %{root: root} do
    first = HookToken.path()
    System.put_env("AIUR_INSTANCE_KEY", "../other")
    assert Path.dirname(HookToken.path()) == root
    refute HookToken.path() == first
    System.delete_env("AIUR_INSTANCE_KEY")
    assert HookToken.read() == {:error, :unconfigured}
  end
end
