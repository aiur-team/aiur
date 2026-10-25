defmodule Aiur.RunTelemetry.LedgerRetentionTest do
  use ExUnit.Case, async: false
  alias Aiur.RunTelemetry.{Ledger, LedgerRetention, Summaries}

  setup do
    root = Path.join(Application.fetch_env!(:aiur, :test_run_root), "ledger-retention-#{System.pid()}-#{System.unique_integer([:positive])}")
    prior = for key <- [:repo_base_root, :analytics_repo, :log_file], do: {key, Application.fetch_env(:aiur, key)}
    enabled_key = {Aiur.RunTelemetry, :telemetry_enabled}
    enabled = :persistent_term.get(enabled_key, :unset)
    :persistent_term.put(enabled_key, true)
    Application.put_env(:aiur, :repo_base_root, root)
    Application.put_env(:aiur, :analytics_repo, "test/ledger")
    Application.put_env(:aiur, :log_file, Path.join(root, "log/aiur.log"))

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, old} -> Application.put_env(:aiur, key, old)
          :error -> Application.delete_env(:aiur, key)
        end
      end

      if enabled == :unset, do: :persistent_term.erase(enabled_key), else: :persistent_term.put(enabled_key, enabled)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root, path: Aiur.RunTelemetry.telemetry_file()}
  end

  test "persists an old boot's dispatch before pruning it", %{root: root, path: path} do
    rows = [
      %{kind: "restart", attributes: %{event: "daemon_restart"}},
      %{kind: "lifecycle", attributes: %{ticket: "42", event: "dispatch", boundary: "point", attempt_id: "a"}},
      %{kind: "restart", attributes: %{event: "daemon_restart"}, boot_id: "B"}
    ]

    File.mkdir_p!(Path.dirname(path))

    body =
      rows
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {row, index} ->
        row
        |> Map.merge(%{schema_version: 3, timestamp: "2026-10-09T10:0#{index}:00Z", boot_id: Map.get(row, :boot_id, "A"), sequence: index, record_id: "row#{index}"})
        |> Jason.encode!()
        |> Kernel.<>("\n")
      end)

    File.write!(path, body)
    reducer = Path.expand("../../../../analytics", __DIR__)
    assert :ok = LedgerRetention.prune(path, max_bytes: 1, protected_boot_id: "B", materialize_opts: [reduce_dir: reducer, logs_root: root])
    refute File.read!(path) =~ "dispatch"
    assert {:ok, record} = Ledger.get("42")
    assert record["milestones"]["first_dispatch"] == %{"at" => "2026-10-09T10:02:00Z", "status" => "observed", "source" => "telemetry"}
    assert File.regular?(Path.join(Summaries.analytics_dir(), "ledger-cursor.json"))
  end

  test "bounds a slow checkpoint and leaves raw telemetry unchanged", %{root: root, path: path} do
    reducer = Path.join(root, "slow-reducer")
    File.mkdir_p!(reducer)
    script = Path.join(reducer, "reduce")
    File.write!(script, "#!/bin/sh\nexec sleep 8\n")
    File.chmod!(script, 0o700)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "unchanged evidence")
    started = System.monotonic_time(:millisecond)
    assert {:error, {:ledger_checkpoint_failed, :materialize_timeout}} = LedgerRetention.prune(path, max_bytes: 1, materialize_opts: [reduce_dir: reducer])
    assert System.monotonic_time(:millisecond) - started < 6_500
    assert File.read!(path) == "unchanged evidence"
  end

  test "preserves raw evidence when the checkpoint fails", %{root: root, path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "unchanged evidence")
    assert {:error, {:ledger_checkpoint_failed, :reduce_unavailable}} = LedgerRetention.prune(path, max_bytes: 1, materialize_opts: [reduce_dir: Path.join(root, "missing")])
    assert File.read!(path) == "unchanged evidence"
  end
end
