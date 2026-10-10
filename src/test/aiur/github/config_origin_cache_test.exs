defmodule Aiur.GitHub.ConfigOriginCacheTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Config, as: GitHubConfig

  @moduletag :tmp_dir
  @key {GitHubConfig, :resolved_origin_repo}

  # The lookup shells out to git, so it is slow next to a cache write. A
  # background reader that started it before a test cached its own origin used
  # to finish afterwards and overwrite that value with the real remote (#4016).
  test "an origin lookup that finishes late keeps the value cached while it ran", %{tmp_dir: dir} do
    previous = :persistent_term.get(@key, :unset)
    path = System.get_env("PATH")
    real_git = System.find_executable("git")
    started = Path.join(dir, "started")
    release = Path.join(dir, "release")

    on_exit(fn ->
      File.touch!(release)
      System.put_env("PATH", path)
      if previous == :unset, do: :persistent_term.erase(@key), else: :persistent_term.put(@key, previous)
    end)

    # Only the origin lookup is held; every other git call passes through.
    File.write!(Path.join(dir, "git"), """
    #!/bin/sh
    [ "$1 $2" = "remote get-url" ] || exec #{real_git} "$@"
    touch #{started}
    while [ ! -e #{release} ]; do sleep 0.01; done
    echo https://github.com/slow/lookup.git
    """)

    File.chmod!(Path.join(dir, "git"), 0o755)
    System.put_env("PATH", dir <> ":" <> path)
    # An explicit repo keeps background readers off the origin lookup, so the
    # only caller held in git is the one this test starts.
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :persistent_term.erase(@key)

    lookup = Task.async(fn -> GitHubConfig.configured_repo_from_value(nil) end)
    wait_for_file!(started)
    :persistent_term.put(@key, "cached/meanwhile")
    File.touch!(release)

    assert Task.await(lookup) == {:ok, {"slow", "lookup"}}
    assert :persistent_term.get(@key) == "cached/meanwhile"
  end

  defp wait_for_file!(path, attempts \\ 500) do
    cond do
      File.exists?(path) -> :ok
      attempts == 0 -> flunk("origin lookup never reached git")
      true -> Process.sleep(10) && wait_for_file!(path, attempts - 1)
    end
  end
end
