defmodule Aiur.DecisionLogTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Aiur.DecisionLog

  defp identity_validator, do: fn decoded -> {:ok, decoded} end

  describe "ensure_directory/1" do
    test "creates an owner-only (0700) directory when absent", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "state")

      assert :ok = DecisionLog.ensure_directory(dir)
      assert File.dir?(dir)
      assert %File.Stat{mode: mode} = File.stat!(dir)
      assert Bitwise.band(mode, 0o777) == 0o700
    end

    test "is idempotent on an existing owner-only directory", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "state")
      assert :ok = DecisionLog.ensure_directory(dir)
      assert :ok = DecisionLog.ensure_directory(dir)
    end

    test "rejects a symlinked directory target", %{tmp_dir: tmp_dir} do
      real_dir = Path.join(tmp_dir, "real")
      File.mkdir_p!(real_dir)
      link = Path.join(tmp_dir, "linked")
      File.ln_s!(real_dir, link)

      assert {:error, {:symlink_rejected, ^link}} = DecisionLog.ensure_directory(link)
    end

    test "rejects a path that is an existing regular file", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "not_a_dir")
      File.write!(file, "x")

      assert {:error, {:not_a_directory, ^file}} = DecisionLog.ensure_directory(file)
    end
  end

  describe "prepare/3" do
    test "syncs first creation once before appends enter the hot path", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "state")
      path = Path.join(dir, "decisions.ndjson")
      test_pid = self()

      sync_fun = fn ->
        send(test_pid, :filesystem_synced)
        :ok
      end

      assert :ok = DecisionLog.prepare(dir, path, sync_fun)
      assert_receive :filesystem_synced
      refute_receive :filesystem_synced

      assert :ok = DecisionLog.append(path, %{"version" => 1})
      refute_receive :filesystem_synced

      assert :ok = DecisionLog.prepare(dir, path, sync_fun)
      refute_receive :filesystem_synced
    end
  end

  describe "append/2 and replay/2 happy path" do
    test "a single accepted event round-trips", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "decisions.ndjson")
      event = %{"decision_id" => "dec_1", "version" => 1}

      assert :ok = DecisionLog.append(path, event)
      assert {:ok, [decoded], nil} = DecisionLog.replay(path, identity_validator())
      assert decoded == event
    end

    test "multiple appends replay in order", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "decisions.ndjson")

      for i <- 1..5 do
        assert :ok = DecisionLog.append(path, %{"decision_id" => "dec_1", "version" => i})
      end

      assert {:ok, decoded, nil} = DecisionLog.replay(path, identity_validator())
      assert Enum.map(decoded, & &1["version"]) == [1, 2, 3, 4, 5]
    end

    test "the file and first-created parent directory end up owner-only", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "state")
      path = Path.join(dir, "decisions.ndjson")
      File.mkdir_p!(dir)

      assert :ok = DecisionLog.append(path, %{"a" => 1})
      assert %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "replaying a missing file returns an empty, intact stream", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing.ndjson")
      assert {:ok, [], nil} = DecisionLog.replay(path, identity_validator())
    end

    test "each appended line is newline-terminated on disk", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "decisions.ndjson")
      assert :ok = DecisionLog.append(path, %{"a" => 1})
      assert :ok = DecisionLog.append(path, %{"a" => 2})

      assert File.read!(path) ==
               Jason.encode!(%{"a" => 1}) <> "\n" <> Jason.encode!(%{"a" => 2}) <> "\n"
    end
  end

  describe "crash recovery" do
    test "a non-newline-terminated trailing fragment is truncated, synced, and excluded", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "decisions.ndjson")
      assert :ok = DecisionLog.append(path, %{"decision_id" => "dec_1", "version" => 1})

      # Simulate a crash mid-append: an incomplete, non-newline-terminated
      # fragment follows the last acknowledged record.
      File.write!(path, ~s({"decision_id":"dec_1","version":2,"trunc), [:append])

      assert {:ok, [decoded], nil} = DecisionLog.replay(path, identity_validator())
      assert decoded["version"] == 1

      # The truncation is itself durable: re-reading the raw file shows the
      # fragment is gone, not just excluded from the in-memory result.
      assert File.read!(path) == Jason.encode!(%{"decision_id" => "dec_1", "version" => 1}) <> "\n"
    end

    test "a file that is only an incomplete fragment truncates to empty", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "decisions.ndjson")
      File.write!(path, ~s({"incomplete))

      assert {:ok, [], nil} = DecisionLog.replay(path, identity_validator())
      assert File.read!(path) == ""
    end

    test "callers can validate a torn prefix without mutating it before their own recovery marker", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "decisions.ndjson")
      assert :ok = DecisionLog.append(path, %{"decision_id" => "dec_1", "version" => 1})
      File.write!(path, ~s({"decision_id":"dec_1","version":2,"trunc), [:append])
      torn_contents = File.read!(path)

      assert {:ok, [decoded], nil} =
               DecisionLog.replay(path, identity_validator(), repair_torn_tail: false)

      assert decoded["version"] == 1
      assert File.read!(path) == torn_contents
    end
  end

  describe "corruption" do
    test "an interior blank record is corruption rather than a skipped delimiter", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "decisions.ndjson")
      File.write!(path, ~s({"version":1}\n\n{"version":3}\n))

      assert {:ok, [first], {:corrupt, 2, _reason}} = DecisionLog.replay(path, identity_validator())
      assert first["version"] == 1
    end

    test "malformed JSON on an interior line halts replay at that line, never skipping forward", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "decisions.ndjson")
      File.write!(path, ~s({"version":1}\n) <> "not json at all\n" <> ~s({"version":3}\n))

      assert {:ok, [first], {:corrupt, 2, _reason}} = DecisionLog.replay(path, identity_validator())
      assert first["version"] == 1
    end

    test "a record that fails the semantic validator halts replay, even though it parses as JSON", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "decisions.ndjson")
      File.write!(path, ~s({"version":1}\n) <> ~s({"version":2}\n))

      validator = fn decoded ->
        if decoded["version"] == 2 do
          {:error, :semantically_invalid}
        else
          {:ok, decoded}
        end
      end

      assert {:ok, [first], {:corrupt, 2, :semantically_invalid}} = DecisionLog.replay(path, validator)
      assert first["version"] == 1
    end
  end

  describe "symlink rejection" do
    test "append/2 refuses to write through a symlinked path", %{tmp_dir: tmp_dir} do
      target = Path.join(tmp_dir, "target.ndjson")
      File.write!(target, "")
      link = Path.join(tmp_dir, "link.ndjson")
      File.ln_s!(target, link)

      assert {:error, {:symlink_rejected, ^link}} = DecisionLog.append(link, %{"a" => 1})
    end

    test "replay/2 refuses to read through a symlinked path", %{tmp_dir: tmp_dir} do
      target = Path.join(tmp_dir, "target.ndjson")
      File.write!(target, Jason.encode!(%{"a" => 1}) <> "\n")
      link = Path.join(tmp_dir, "link.ndjson")
      File.ln_s!(target, link)

      assert {:error, {:symlink_rejected, ^link}} = DecisionLog.replay(link, identity_validator())
    end
  end
end
