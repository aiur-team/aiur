defmodule Aiur.Gateway.RegistryTest do
  use ExUnit.Case, async: false

  alias Aiur.Gateway.Registry

  @id "aaaaaaaaaaaaaaaaaaaaaaaaaa"
  @other "bbbbbbbbbbbbbbbbbbbbbbbbbb"
  @awk Path.expand("../../../../packaging/npm/aiur-cli/libexec/engine/registry.awk", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "gw-registry-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "remote-instances.yaml")
    audit = Path.join(root, "control-audit.ndjson")
    previous = {Application.get_env(:aiur, :gateway_registry_path), Application.get_env(:aiur, :control_audit_file)}
    Application.put_env(:aiur, :gateway_registry_path, path)
    Application.put_env(:aiur, :control_audit_file, audit)

    on_exit(fn ->
      restore(:gateway_registry_path, elem(previous, 0))
      restore(:control_audit_file, elem(previous, 1))
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{path: path, audit: audit}
  end

  test "a missing file is an empty registry" do
    assert {:ok, %{peers: peers}} = Registry.get()
    assert peers == %{}
  end

  test "an entry with no allows block permits read only", %{path: path} do
    File.write!(path, entry("nook", @id, ""))
    assert {:ok, %{peers: %{"nook" => peer}}} = Registry.get()
    assert peer.categories == ["read"]
    assert peer.credentials == []
  end

  test "an empty categories list means no access at all", %{path: path} do
    File.write!(path, entry("nook", @id, "    allows:\n      categories: []\n"))
    assert {:ok, %{peers: %{"nook" => %{categories: []}}}} = Registry.get()
  end

  test "a hand edit applies on the next call and is audited as an unknown local editor", %{path: path, audit: audit} do
    File.write!(path, entry("nook", @id, ""))
    assert {:ok, %{peers: %{"nook" => %{categories: ["read"]}}}} = Registry.get()

    File.write!(path, entry("nook", @id, "    allows:\n      categories: [read, agents]\n"))
    assert {:ok, %{peers: %{"nook" => %{categories: ["read", "agents"]}}}} = Registry.get()

    assert [%{"event" => "file_edit_detected", "actor" => "unknown_local_editor", "peer" => @id}] = records(audit)
  end

  test "an inline token is rejected naming the key and the last good registry stays in force", %{path: path} do
    File.write!(path, entry("nook", @id, "    allows:\n      categories: [read, agents]\n"))
    assert {:ok, %{last_error: nil}} = Registry.get()

    File.write!(path, entry("nook", @id, "    allows:\n      categories: [read, agents, message]\n    token: abc\n"))
    assert {:ok, %{peers: %{"nook" => peer}, last_error: {:invalid, "token", _}}} = Registry.get()
    assert peer.categories == ["read", "agents"]
  end

  test "trust in categories is rejected naming trust and the last good registry stays", %{path: path} do
    File.write!(path, entry("nook", @id, "    allows:\n      categories: [read]\n"))
    assert {:ok, _} = Registry.get()

    File.write!(path, entry("nook", @id, "    allows:\n      categories: [read, trust]\n"))
    assert {:ok, %{peers: %{"nook" => %{categories: ["read"]}}, last_error: {:invalid, "trust", _}}} = Registry.get()
  end

  test "an invalid file with no last good value is an error naming the key", %{path: path} do
    File.write!(path, entry("nook", @id, "    token: abc\n"))
    assert {:error, {:invalid, "token", _}} = Registry.get()
  end

  test "a duplicated gateway_id is rejected", %{path: path} do
    File.write!(path, entry("nook", @id, "") <> "  pc:\n    gateway_id: \"#{@id}\"\n")
    assert {:error, {:invalid, "gateway_id", _}} = Registry.get()
  end

  test "write persists mode 0600, keeps the launcher parser able to read it, and audits the change", %{path: path, audit: audit} do
    File.write!(path, entry("nook", @id, ""))

    assert :ok = Registry.write(&put_categories(&1, "nook", ["read", "agents"]), "cli_local")

    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert {:ok, %{peers: %{"nook" => %{categories: ["read", "agents"]}}}} = Registry.get()
    assert {out, 0} = System.cmd("awk", ["-f", @awk, "-v", "target=nook", "-v", "display=test", path], stderr_to_stdout: true)
    assert out =~ "url\thttps://nook.example"

    assert [%{"event" => "grant_written", "actor" => "cli_local", "peer" => @id, "categories" => ["read", "agents"]}] = records(audit)
  end

  test "write refuses a change that would make the file invalid and leaves it alone", %{path: path} do
    File.write!(path, entry("nook", @id, ""))
    before = File.read!(path)

    assert {:error, {:invalid, "trust", _}} = Registry.write(&put_categories(&1, "nook", ["read", "trust"]), "cli_local")
    assert File.read!(path) == before
  end

  test "two writers from separate processes both land", %{path: path} do
    File.write!(path, entry("nook", @id, "") <> entry_body("pc", @other, ""))

    tasks = [
      Task.async(fn -> Registry.write(&put_categories(&1, "nook", ["read", "agents"]), "cli_local") end),
      Task.async(fn -> Registry.write(&put_categories(&1, "pc", ["read", "message"]), "cli_local") end)
    ]

    assert Enum.map(tasks, &Task.await/1) == [:ok, :ok]
    assert {:ok, %{peers: %{"nook" => nook, "pc" => pc}}} = Registry.get()
    assert nook.categories == ["read", "agents"]
    assert pc.categories == ["read", "message"]
  end

  defp put_categories(instances, name, categories) do
    Map.update!(instances, name, fn entry -> Map.put(entry, "allows", %{"categories" => categories}) end)
  end

  defp entry(name, id, allows), do: "version: 1\ninstances:\n" <> entry_body(name, id, allows)

  defp entry_body(name, id, allows) do
    "  #{name}:\n    url: https://#{name}.example\n    token_env: AIUR_TOKEN_T\n    gateway_id: \"#{id}\"\n" <> allows
  end

  defp records(path), do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp restore(key, nil), do: Application.delete_env(:aiur, key)
  defp restore(key, value), do: Application.put_env(:aiur, key, value)
end
