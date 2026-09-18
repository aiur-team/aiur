defmodule Aiur.CIApprovalStoreTest do
  # Mutates the global :log_file, :decision_state_dir and
  # :ci_approval_store_path application env, so it cannot run async.
  use ExUnit.Case, async: false

  alias Aiur.CIApprovalStore
  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  setup do
    root = Path.join(System.tmp_dir!(), "ci-approval-store-#{System.unique_integer([:positive])}")
    keys = [:log_file, :decision_state_dir, :ci_approval_store_path]
    previous = Map.new(keys, &{&1, Application.fetch_env(:aiur, &1)})

    Application.delete_env(:aiur, :ci_approval_store_path)
    Application.put_env(:aiur, :decision_state_dir, Path.join(root, "state"))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:aiur, key, value)
        {key, :error} -> Application.delete_env(:aiur, key)
      end)

      File.rm_rf!(root)
    end)

    %{logs_parent: Path.join(root, "logs"), state_dir: Path.join(root, "state")}
  end

  # A launched daemon logs to `<logs-parent>/<launch>/log/aiur.log`; a restart
  # is a new launch directory.
  defp launch(logs_parent, stamp) do
    Application.put_env(:aiur, :log_file, Path.join([logs_parent, stamp, "log", "aiur.log"]))
  end

  defp legacy_file(logs_parent, stamp),
    do: Path.join([logs_parent, stamp, "log", "#{Paths.repo_name()}.ci-approvals.json"])

  defp write_legacy(logs_parent, stamp, approved_heads, mtime) do
    path = legacy_file(logs_parent, stamp)

    JsonStore.write!(path, %{
      "approved_heads" => approved_heads,
      "test_failure_heads" => %{},
      "base_repair_invalidations" => %{}
    })

    File.touch!(path, mtime)
    path
  end

  test "approved heads and the base-repair journal survive a restart with a new log directory",
       %{logs_parent: logs_parent, state_dir: state_dir} do
    launch(logs_parent, "20260917T160044Z-1")

    assert :ok = CIApprovalStore.save(%{"101" => "approved-sha"}, %{"102" => "flaky-sha"})

    assert :ok =
             CIApprovalStore.journal_base_repair("103", %{
               head_sha: "repair-sha",
               repaired_at: 1_700_000_000,
               repair_state: :repairing
             })

    assert CIApprovalStore.path_for() == Path.join(state_dir, "ci-approvals.json")

    launch(logs_parent, "20260918T011606Z-2")

    assert %{
             approved_heads: %{"101" => "approved-sha"},
             test_failure_heads: %{"102" => "flaky-sha"},
             base_repair_invalidations: %{
               "103" => %{head_sha: "repair-sha", repaired_at: 1_700_000_000, repair_state: :repairing}
             }
           } = CIApprovalStore.load()

    refute File.exists?(legacy_file(logs_parent, "20260918T011606Z-2"))
  end

  test "adopts the newest per-launch file exactly once", %{logs_parent: logs_parent, state_dir: state_dir} do
    write_legacy(logs_parent, "20260917T160044Z-1", %{"101" => "old-sha"}, 1_700_000_000)
    write_legacy(logs_parent, "20260918T011606Z-2", %{"101" => "newest-sha"}, 1_700_000_100)

    other_repo = Path.join([logs_parent, "20260918T025027Z-3", "log", "other-repo.ci-approvals.json"])
    JsonStore.write!(other_repo, %{"approved_heads" => %{"101" => "other-repo-sha"}})
    File.touch!(other_repo, 1_700_000_200)

    launch(logs_parent, "20260918T030000Z-4")

    assert %{approved_heads: %{"101" => "newest-sha"}} = CIApprovalStore.load()
    assert File.exists?(Path.join(state_dir, "ci-approvals.json"))

    # The adopted state now moves on; a later per-launch file must not replace it.
    assert :ok = CIApprovalStore.save(%{"101" => "durable-sha"}, %{})
    write_legacy(logs_parent, "20260918T040000Z-5", %{"101" => "stale-legacy-sha"}, 1_700_000_300)

    launch(logs_parent, "20260918T050000Z-6")

    assert %{approved_heads: %{"101" => "durable-sha"}} = CIApprovalStore.load()
  end

  test "without any legacy file the store starts empty and never adopts later",
       %{logs_parent: logs_parent} do
    launch(logs_parent, "20260918T030000Z-1")

    assert %{approved_heads: heads} = CIApprovalStore.load()
    assert heads == %{}

    write_legacy(logs_parent, "20260918T040000Z-2", %{"101" => "late-legacy-sha"}, 1_700_000_300)
    launch(logs_parent, "20260918T050000Z-3")

    assert %{approved_heads: heads} = CIApprovalStore.load()
    assert heads == %{}
  end

  test "an explicit store path wins over the state directory", %{logs_parent: logs_parent, state_dir: state_dir} do
    launch(logs_parent, "20260918T030000Z-1")
    explicit = Path.join(state_dir, "explicit.json")
    Application.put_env(:aiur, :ci_approval_store_path, explicit)

    assert CIApprovalStore.path_for() == explicit
  end
end
