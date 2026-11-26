defmodule Aiur.Handoff.RecordTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.Handoff, as: RunnerHandoff
  alias Aiur.Handoff.Record
  alias Aiur.JsonStore

  @now ~U[2026-10-14 12:00:00Z]

  setup do
    dir = Path.join(System.tmp_dir!(), "handoff-record-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    {:ok, opts: [dir: dir, now: @now, orphan_timeout_ms: 60_000]}
  end

  test "round-trips the envelope and nested agent continuation data", %{opts: opts} do
    record = record()
    assert :none = Record.read(opts)
    assert :ok = Record.write(record, opts)
    assert {:ok, ^record} = Record.read(opts)
    assert Record.path(opts) == Path.join([opts[:dir], "handoff", "current.json"])
  end

  test "unknown schema is rejected but raw agents remain available for fallback", %{opts: opts} do
    record = Map.put(record(), "handoff_schema", 99)
    JsonStore.write!(Record.path(opts), record)
    assert {:error, :schema} = Record.read(opts)
    assert {:error, :schema} = Record.write(record, opts)
    assert {:ok, ^record} = Record.read_raw(opts)
  end

  test "a filesystem write failure returns an error for prepare rollback", %{opts: opts} do
    File.mkdir_p!(Record.path(opts))
    assert {:error, %File.Error{reason: :eisdir}} = Record.write(record(), opts)
  end

  test "corrupt JSON and malformed envelopes fail closed", %{opts: opts} do
    File.mkdir_p!(Path.dirname(Record.path(opts)))
    File.write!(Record.path(opts), "{unfinished")
    assert {:error, :schema} = Record.read(opts)

    for invalid <- [[], %{}, Map.put(record(), "written_at", "yesterday"), Map.put(record(), "agents", [nil])] do
      JsonStore.write!(Record.path(opts), invalid)
      assert {:error, :schema} = Record.read(opts)
    end
  end

  test "consume archives outcome exactly once and removes the boot record", %{opts: opts} do
    record = record()
    assert :ok = Record.write(record, opts)
    outcome = %{"3844" => "adopted"}
    assert :ok = Record.consume(outcome, opts)
    assert :none = Record.read(opts)
    assert {:error, :already_consumed} = Record.consume(%{"3844" => "fallback"}, opts)
    assert {:ok, archived} = JsonStore.read(Record.path(opts) <> ".consumed")
    assert Map.delete(archived, "completed_at") == Map.put(record, "outcome", outcome)
    assert {:ok, _, _} = DateTime.from_iso8601(archived["completed_at"])
  end

  test "an in-daemon record and its archived copy are owner-only", %{opts: opts} do
    record = in_daemon_record()
    assert :ok = Record.write(record, opts)

    file = Record.path(opts)
    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(file)).mode, 0o777) == 0o700

    assert :ok = Record.consume([%{"status" => "adopted"}], opts)

    consumed = file <> ".consumed"
    assert Bitwise.band(File.stat!(consumed).mode, 0o777) == 0o600
    assert {:ok, archived} = JsonStore.read(consumed)
    # The archived copy keeps the adoption outcome but not the conversation.
    refute Jason.encode!(archived) =~ "workspace evidence"
    assert get_in(archived, ["agents", Access.at(0), "transport", "provider_state"]) == nil
    assert get_in(archived, ["agents", Access.at(0), "issue_id"]) == "3844"
  end

  test "records older than the relay orphan timeout are stale", %{opts: opts} do
    old = Map.put(record(), "written_at", DateTime.to_iso8601(DateTime.add(@now, -61, :second)))
    JsonStore.write!(Record.path(opts), old)
    assert {:error, :stale} = Record.read(opts)
    assert {:ok, ^old} = Record.read_raw(opts)

    boundary = Map.put(old, "written_at", DateTime.to_iso8601(DateTime.add(@now, -60, :second)))
    JsonStore.write!(Record.path(opts), boundary)
    assert {:ok, ^boundary} = Record.read(opts)
  end

  defp in_daemon_record do
    provider_state =
      RunnerHandoff.encode(%{
        "messages" => [%{"role" => "tool", "content" => "workspace evidence"}],
        "interrupted" => false
      })

    %{
      "handoff_schema" => 1,
      "handoff_id" => "restart-in-daemon",
      "written_at" => DateTime.to_iso8601(@now),
      "from_version" => "0.1.0+abc123",
      "generation" => 2,
      "config_fingerprint" => "digest",
      "agents" => [
        %{
          "issue_id" => "3844",
          "backend" => "openrouter",
          "transport" => %{"kind" => "in_daemon", "provider_state" => provider_state}
        }
      ]
    }
  end

  defp record do
    %{
      "handoff_schema" => 1,
      "handoff_id" => "restart-1",
      "written_at" => DateTime.to_iso8601(@now),
      "from_version" => "0.1.0+abc123",
      "generation" => 2,
      "config_fingerprint" => "digest",
      "agents" => [%{"issue_id" => "3844", "pending_requests" => [%{"id" => 7, "method" => "turn/start"}], "acked_offset" => 41}]
    }
  end
end
