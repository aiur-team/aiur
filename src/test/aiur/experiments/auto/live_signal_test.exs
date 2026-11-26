defmodule Aiur.Experiments.Auto.LiveSignalTest do
  use ExUnit.Case, async: true
  alias Aiur.Config.Schema.Experiments.Auto, as: Config
  alias Aiur.Experiments.Auto.LiveSignal

  setup do
    repo = Path.join(System.tmp_dir!(), "feature-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["config", "user.name", "Test"])
    git!(repo, ["remote", "add", "origin", "https://github.com/owner/repo.git"])
    git!(repo, ["commit", "--allow-empty", "-m", "before"])
    old = git!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["commit", "--allow-empty", "-m", "feature"])
    sha = git!(repo, ["rev-parse", "HEAD"])
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(repo) end)
    %{repo: repo, old: old, sha: sha, merge: %{"at" => "2026-10-10T00:00:00Z", "sha" => sha}}
  end

  test "first containing boot wins, unknown and earlier SHAs cannot set the line", %{repo: repo, old: old, sha: sha, merge: merge} do
    rows = [
      %{"at" => "2026-10-10T01:00:00Z", "source_sha" => old},
      %{"at" => "2026-10-10T02:00:00Z", "source_sha" => String.duplicate("f", 40)},
      %{"at" => "2026-10-10T03:00:00Z", "source_sha" => sha, "boot_id" => "live"}
    ]

    opts = [repo: repo, deploys: fn _range -> {:ok, rows} end]
    assert {:ok, line} = LiveSignal.resolve(merge, %Config{feature_live_signal: "daemon_boot"}, ~U[2026-10-10 04:00:00Z], opts)
    assert line["at"] == "2026-10-10T03:00:00Z"
    assert line["boot_id"] == "live"
    refute Map.has_key?(line, "live_signal_fallback")
    unknown = Keyword.put(opts, :deploys, fn _range -> {:ok, Enum.take(rows, 2)} end)
    assert :pending = LiveSignal.resolve(merge, %Config{feature_live_signal: "daemon_boot"}, ~U[2026-10-12 23:59:59Z], unknown)
    assert {:ok, fallback} = LiveSignal.resolve(merge, %Config{feature_live_signal: "daemon_boot"}, ~U[2026-10-13 00:00:00Z], unknown)
    assert fallback["at"] == merge["at"]
    assert fallback["live_signal_fallback"] == true
  end

  test "auto verifies the build repository and release chooses the first containing tag", %{repo: repo, old: old, sha: sha, merge: merge} do
    assert LiveSignal.signal("auto", repo, stamp: %{source_sha: sha}, build_repo: repo, managed_repo: "owner/repo") == "daemon_boot"
    assert LiveSignal.signal("auto", repo, stamp: %{source_sha: nil}, build_repo: repo, managed_repo: "owner/repo") == "merge"
    assert LiveSignal.signal("auto", repo, stamp: %{source_sha: sha}, build_repo: repo, managed_repo: "other/repo") == "merge"
    git!(repo, ["tag", "v1.0.0", old])
    git!(repo, ["tag", "v1.1.0", sha])
    # TagReader fetches locally from origin; a bare remote keeps this a real git boundary.
    remote = Path.join(repo, "remote.git")
    git!(repo, ["clone", "--bare", repo, remote])
    git!(repo, ["remote", "set-url", "origin", remote])
    path = Path.join(repo, "seen.json")
    File.write!(path, Jason.encode!(["v1.0.0", "v1.1.0"]))
    assert {:ok, line} = LiveSignal.resolve(merge, %Config{feature_live_signal: "release"}, DateTime.utc_now(), repo: repo, release_path: path)
    assert line["tag"] == "v1.1.0"
    assert line["live_signal"] == "release"
    refute line["live_signal_fallback"]
  end

  defp git!(repo, args) do
    {out, status} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    assert status == 0, out
    String.trim(out)
  end
end
