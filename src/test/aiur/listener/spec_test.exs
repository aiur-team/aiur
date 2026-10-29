defmodule Aiur.Listener.SpecTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias Aiur.Listener.Spec

  setup do
    root = Path.join(System.tmp_dir!(), "listener-spec-#{System.unique_integer([:positive])}")
    key = {Spec, root}
    installed_key = {Spec, Application.app_dir(:aiur, "priv/listener_spec")}
    previous = :persistent_term.get(installed_key, :missing)
    :persistent_term.erase(installed_key)

    on_exit(fn ->
      :persistent_term.erase(key)
      :persistent_term.erase(installed_key)
      if previous != :missing, do: :persistent_term.put(installed_key, previous)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root}
  end

  test "installed contract exposes modes, statuses and complete scheduler rows" do
    assert Spec.status() == :ok
    assert Spec.modes() == ["steer", "sync", "async", "mute"]
    assert Spec.support_statuses() == ["proven", "experimental", "blocked_without_wrapper", "unsupported", "unknown"]
    rows = Spec.scheduler_rows()
    assert length(rows) == 1024
    assert Enum.all?(rows, &Map.has_key?(&1, "delivers"))
    assert Enum.any?(rows, &(&1["delivers"] == true))
    assert Enum.any?(rows, &(&1["mode"] == "mute"))
  end

  test "status is not_installed when the priv directory is absent and logs once", %{root: root} do
    assert capture_log(fn ->
             assert Spec.status(root) == {:error, :not_installed}
             assert Spec.status(root) == {:error, :not_installed}
           end) =~ "not_installed"

    assert capture_log(fn -> assert Spec.status(root) == {:error, :not_installed} end) == ""
  end

  test "status is spec_invalid after one vendored byte changes", %{root: root} do
    copy_spec(root)
    File.write!(Path.join(root, "v1/scheduler.v1.json"), " ", [:append])
    assert Spec.status(root) == {:error, :spec_invalid}
  end

  test "status is cached for the boot after initial validation", %{root: root} do
    copy_spec(root)
    assert Spec.status(root) == :ok
    File.write!(Path.join(root, "v1/scheduler.v1.json"), "invalid")
    assert Spec.status(root) == :ok
  end

  test "partial installation, extra files and symlinks fail closed", %{root: root} do
    for corrupt <- [
          fn -> File.rm!(Path.join(root, "CHECKSUM")) end,
          fn -> File.write!(Path.join(root, "v1/extra.json"), "{}") end,
          fn -> File.ln_s!("scheduler.v1.json", Path.join(root, "v1/link")) end
        ] do
      copy_spec(root)
      corrupt.()
      assert Spec.status(root) == {:error, :spec_invalid}
      :persistent_term.erase({Spec, root})
      Aiur.TestCleanup.rm_rf!(root)
    end
  end

  test "repinning CHECKSUM alone cannot bypass the upstream manifest", %{root: root} do
    copy_spec(root)
    File.write!(Path.join(root, "v1/scheduler.v1.json"), "[]")
    repin(root)
    assert Spec.status(root) == {:error, :spec_invalid}
  end

  test "checksum-valid undecodable or structurally invalid spec fails closed", %{root: root} do
    for content <- ["{", "[]", "null", ~s([{"mode":"sync"}])] do
      copy_spec(root)
      File.write!(Path.join(root, "v1/scheduler.v1.json"), content)
      repin_manifest(root)
      repin(root)
      assert Spec.status(root) == {:error, :spec_invalid}
      :persistent_term.erase({Spec, root})
      Aiur.TestCleanup.rm_rf!(root)
    end
  end

  defp copy_spec(root), do: File.cp_r!(Application.app_dir(:aiur, "priv/listener_spec"), root)

  defp repin_manifest(root) do
    path = Path.join(root, "v1/MANIFEST.json")
    manifest = Jason.decode!(File.read!(path))
    files = Enum.map(manifest["files"], &Map.put(&1, "sha256", hash(Path.join(root, "v1/" <> &1["path"]))))
    File.write!(path, Jason.encode!(%{manifest | "files" => files}))
  end

  defp repin(root) do
    checksum = Path.join(root, "CHECKSUM")
    headers = checksum |> File.read!() |> String.split("\n") |> Enum.take(2)
    paths = root |> Path.join("v1/**/*") |> Path.wildcard() |> Enum.reject(&File.dir?/1)
    rows = Enum.map(paths, &(hash(&1) <> "  " <> Path.relative_to(&1, root)))
    File.write!(checksum, Enum.join(headers ++ rows, "\n") <> "\n")
  end

  defp hash(path), do: :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
end
