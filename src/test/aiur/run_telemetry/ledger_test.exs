defmodule Aiur.RunTelemetry.LedgerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Aiur.RunTelemetry.{Ledger, Summaries}

  setup do
    root = Aiur.TestSupport.tmp_root!("ticket-ledger")
    prior = for key <- [:repo_base_root, :analytics_repo], do: {key, Application.fetch_env(:aiur, key)}
    enabled_key = {Aiur.RunTelemetry, :telemetry_enabled}
    enabled = :persistent_term.get(enabled_key, :unset)
    :persistent_term.put(enabled_key, true)
    Application.put_env(:aiur, :repo_base_root, root)
    Application.put_env(:aiur, :analytics_repo, "test/ledger")

    on_exit(fn ->
      File.rm_rf!(root)

      for {key, value} <- prior do
        case value do
          {:ok, old} -> Application.put_env(:aiur, key, old)
          :error -> Application.delete_env(:aiur, key)
        end
      end

      if enabled == :unset, do: :persistent_term.erase(enabled_key), else: :persistent_term.put(enabled_key, enabled)
    end)

    %{root: root, enabled_key: enabled_key}
  end

  test "reads canonical records and filters by window and cohort" do
    File.mkdir_p!(Summaries.ledger_dir())
    record = %{"schema_version" => 1, "ticket" => "42", "milestones" => %{}, "last_event_at" => "2026-10-09T10:00:00Z", "cohort" => %{"backend" => "claude"}}
    File.write!(Path.join(Summaries.ledger_dir(), "42.json"), Jason.encode!(record))
    assert {:ok, ^record} = Ledger.get("42")
    assert {:error, :invalid_ticket} = Ledger.get("../42")
    assert {:error, :missing} = Ledger.get("43")
    assert {:ok, [^record]} = Ledger.list(window: {"2026-10-09T09:00:00Z", "2026-10-09T11:00:00Z"}, cohort: %{backend: "claude"})
    assert {:ok, []} = Ledger.list(cohort: %{backend: "codex"})
    assert {:ok, []} = Ledger.list(window: {"2026-10-10T09:00:00Z", "2026-10-10T11:00:00Z"})
    File.write!(Path.join(Summaries.ledger_dir(), "43.json"), "{broken")
    assert capture_log(fn -> assert {:ok, [^record]} = Ledger.list() end) =~ "ticket_ledger unreadable"
  end

  test "disabled telemetry prevents reads and materialization", %{enabled_key: enabled_key} do
    :persistent_term.put(enabled_key, false)
    assert {:error, :disabled} = Ledger.get("42")
    assert {:error, :disabled} = Ledger.list()
    assert :unavailable = Summaries.reduce_command(telemetry_file: "not-used")
  end

  test "segment materialization passes retained launches and current telemetry", %{root: root} do
    reduce_dir = Path.join(root, "tool")
    File.mkdir_p!(reduce_dir)
    File.write!(Path.join(reduce_dir, "reduce"), "")
    assert {:ok, {_script, args}} = Summaries.reduce_command(reduce_dir: reduce_dir, telemetry_file: Path.join(root, "current/telemetry.ndjson"), logs_root: root)
    assert "--ledger" in args
    assert Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?(["--telemetry-glob", Path.join(root, "**/telemetry.ndjson*")])
    assert Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?(["--telemetry", Path.join(root, "current/telemetry.ndjson")])
  end
end
