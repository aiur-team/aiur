defmodule Aiur.BuildStatusTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildStatus
  alias Aiur.RecentMerge

  @now ~U[2026-10-22 18:13:00Z]

  test "counts cached merges newer than the stamped build and names the newest PR" do
    merges = [merge(901, "aabbccdd", ~U[2026-10-22 18:12:00Z]), merge(900, "11223344", ~U[2026-10-22 18:11:00Z])]

    status = BuildStatus.present(%{source_sha: "11223344", built_at: "2026-10-22T05:08:00Z"}, merges, @now, "main")

    assert status == %{
             sha: "11223344",
             built_at: ~U[2026-10-22 05:08:00Z],
             age: "13h",
             base_branch: "main",
             behind: 1,
             newest_pr: 901
           }

    assert BuildStatus.render(status) == "BUILD 11223344 built 13h ago · 1 commit behind origin/main (#901)"
  end

  test "stamp SHA after the cached newest commit stays unknown rather than zero" do
    newest = merge(901, "aabbccdd", ~U[2026-10-22 18:12:00Z])
    status = BuildStatus.present(%{source_sha: "deadbeef"}, [newest], @now, "main")

    assert status.behind == nil
    assert BuildStatus.render(status) == "BUILD deadbeef built unknown ago · unknown commits behind origin/main"
  end

  test "unknown or unmatched main never claims the build is current" do
    for merges <- [:unknown, []] do
      status = BuildStatus.present(%{source_sha: "deadbeef"}, merges, @now, "main")
      assert status.behind == nil
      assert BuildStatus.render(status) == "BUILD deadbeef built unknown ago · unknown commits behind origin/main"
    end
  end

  test "a build at the cached main head has zero commits behind" do
    status = BuildStatus.present(%{source_sha: "aabbccdd", built_at: "2026-10-22T18:12:00Z"}, [merge(901, "aabbccdd", ~U[2026-10-22 18:12:00Z])], @now, "main")

    assert status.behind == 0
    assert BuildStatus.render(status) == "BUILD aabbccdd built 1m ago · 0 commits behind origin/main"
  end

  test "reads the build stamp from the running release directory" do
    release_dir = Path.join(System.tmp_dir!(), "aiur-build-status-#{System.unique_integer([:positive])}")
    File.mkdir_p!(release_dir)
    File.write!(Path.join(release_dir, "AIUR_BUILD_STAMP"), "source_sha=11223344\nbuilt_at=2026-10-22T05:08:00Z\n")

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(release_dir) end)

    status =
      BuildStatus.current(
        release_dir: release_dir,
        merges: [merge(901, "aabbccdd", @now), merge(900, "11223344", @now)],
        now: @now,
        base_branch: "main"
      )

    assert status.sha == "11223344"
    assert status.age == "13h"
    assert status.behind == 1
    assert status.newest_pr == 901
  end

  test "the display names the configured integration branch" do
    status = BuildStatus.present(%{source_sha: "aabbccdd"}, [], @now, "release")

    assert BuildStatus.render(status) == "BUILD aabbccdd built unknown ago · unknown commits behind origin/release"
  end

  defp merge(number, sha, merged_at) do
    %RecentMerge{
      schema_version: 1,
      id: "aiur-team/aiur##{number}",
      repository: "aiur-team/aiur",
      number: number,
      url: "https://github.com/aiur-team/aiur/pull/#{number}",
      merged_at: merged_at,
      observation_source: :github_events,
      backfilled?: true,
      live_observed?: false,
      first_observed_at: @now,
      last_observed_at: @now,
      reconciled_ticket_ids: [],
      merge_commit_sha: sha,
      content_hash: "hash"
    }
  end
end
