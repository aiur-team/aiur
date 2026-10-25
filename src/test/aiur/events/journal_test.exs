defmodule Aiur.Events.JournalTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.Journal

  @moduletag :tmp_dir

  test "replay returns the validated records of an intact journal", %{tmp_dir: dir} do
    path = Path.join(dir, "events.ndjson")
    assert :ok = Journal.prepare(dir, path)
    records = Enum.map(1..3, &%{"id" => &1})
    Enum.each(records, fn record -> assert :ok = Journal.append(path, record) end)

    assert {:ok, [1, 2, 3]} = Journal.replay(path, fn record -> {:ok, record["id"]} end)
  end

  test "replay reports interior corruption once through the injected reporter", %{tmp_dir: dir} do
    path = Path.join(dir, "events.ndjson")
    File.write!(path, ~s({"id":1}\nnot-json\n{"id":2}\n))
    test_pid = self()
    reporter = fn line, reason -> send(test_pid, {:corrupt, line, reason}) end

    assert {:error, {:corrupt, 2, reason}} = Journal.replay(path, &{:ok, &1}, on_corrupt: reporter)
    assert_receive {:corrupt, 2, ^reason}, 1000
    refute_received {:corrupt, _, _}
  end

  test "replay maps an unreadable journal to journal_unavailable", %{tmp_dir: dir} do
    target = Path.join(dir, "target.ndjson")
    path = Path.join(dir, "symlink.ndjson")
    File.write!(target, "")
    File.ln_s!(target, path)

    assert {:error, {:journal_unavailable, {:symlink_rejected, ^path}}} = Journal.replay(path, &{:ok, &1})
  end

  test "append then replay round-trips byte-identically to the kernel journal", %{tmp_dir: dir} do
    facade_path = Path.join(dir, "facade.ndjson")
    kernel_path = Path.join(dir, "kernel.ndjson")
    records = [%{"id" => 1, "message" => "first"}, %{"id" => 2, "message" => "second"}]

    Enum.each(records, fn record ->
      assert :ok = Journal.append(facade_path, record)
      assert :ok = Aiur.Journal.append(kernel_path, record)
    end)

    assert File.read!(facade_path) == File.read!(kernel_path)
    assert {:ok, ^records} = Journal.replay(facade_path, &{:ok, &1})
  end

  test "replay forwards torn-tail repair options to the kernel", %{tmp_dir: dir} do
    path = Path.join(dir, "events.ndjson")
    bytes = ~s({"id":1}\n{"id":)
    File.write!(path, bytes)

    assert {:ok, [%{"id" => 1}]} = Journal.replay(path, &{:ok, &1}, repair_torn_tail: false)
    assert File.read!(path) == bytes
    assert {:ok, [%{"id" => 1}]} = Journal.replay(path, &{:ok, &1})
    assert File.read!(path) == ~s({"id":1}\n)
  end

  test "replay propagates reporter failures", %{tmp_dir: dir} do
    path = Path.join(dir, "events.ndjson")
    File.write!(path, "not-json\n")

    assert_raise RuntimeError, "reporter failed", fn ->
      Journal.replay(path, &{:ok, &1}, on_corrupt: fn _, _ -> raise "reporter failed" end)
    end
  end
end
