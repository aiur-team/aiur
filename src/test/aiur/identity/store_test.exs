defmodule Aiur.Identity.StoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.Identity.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-identity-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, path: Path.join(dir, "identity.json")}
  end

  test "directory precedence honors explicit, app, launcher and XDG roots", %{dir: dir} do
    names = ~w(AIUR_BG_STATE_DIR XDG_CONFIG_HOME)
    previous = Map.new(names, &{&1, System.get_env(&1)})
    app_dir = Application.get_env(:aiur, :machine_state_dir)

    on_exit(fn ->
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      Application.put_env(:aiur, :machine_state_dir, app_dir)
    end)

    System.put_env("AIUR_BG_STATE_DIR", Path.join(dir, "launcher"))
    System.put_env("XDG_CONFIG_HOME", Path.join(dir, "xdg"))
    Application.put_env(:aiur, :machine_state_dir, Path.join(dir, "app"))
    assert Store.dir(dir: Path.join(dir, "explicit")) == Path.join(dir, "explicit")
    assert Store.dir() == Path.join(dir, "app")
    Application.delete_env(:aiur, :machine_state_dir)
    assert Store.dir() == Path.join(dir, "launcher/machine")
    System.delete_env("AIUR_BG_STATE_DIR")
    assert Store.dir() == Path.join(dir, "xdg/aiur/machine")
    System.delete_env("XDG_CONFIG_HOME")
    assert Store.dir() == Path.join(System.user_home!(), ".config/aiur/machine")
  end

  test "creation cannot replace an existing corrupt file", %{dir: dir, path: path} do
    File.write!(path, "corrupt")
    assert :ok = Store.create(dir, %{schema_version: 1, machine_id: String.duplicate("a", 26)})
    assert File.read!(path) == "corrupt"
    assert File.ls!(dir) == ["identity.json"]
  end

  test "stale temp files are neither read nor removed", %{dir: dir, path: path} do
    stale = Path.join(dir, "identity.json.tmp.crashed")
    File.write!(stale, "partial")
    assert :ok = Store.create(dir, fixture())
    assert {:ok, %{machine_id: "aaaaaaaaaaaaaaaaaaaaaaaaaa"}} = Store.read(dir)
    assert File.read!(stale) == "partial"
    assert File.exists?(path)
  end

  test "existing broad modes are warned about and preserved", %{dir: dir, path: path} do
    File.write!(path, Jason.encode!(fixture()))
    File.chmod!(path, 0o644)
    log = capture_log(fn -> assert {:ok, %{machine_label: "machine"}} = Store.read(dir) end)
    assert log =~ "Machine identity has wider permissions"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o644
  end

  test "read errors are returned without altering the existing path", %{dir: dir, path: path} do
    File.mkdir!(path)
    assert {:error, :eisdir} = Store.read(dir)
    assert File.dir?(path)
  end

  test "id validation rejects a trailing newline", %{dir: dir, path: path} do
    File.write!(path, Jason.encode!(Map.put(fixture(), :machine_id, String.duplicate("a", 26) <> "\n")))
    assert {:error, :invalid_machine_id} = Store.read(dir)
  end

  defp fixture do
    %{schema_version: 1, machine_id: String.duplicate("a", 26), machine_label: "machine", created_at: "2026-10-06T16:00:00Z"}
  end
end
