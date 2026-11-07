defmodule Aiur.Intent.StoreTest do
  use ExUnit.Case, async: true

  import Aiur.IntentFixtures

  alias Aiur.Intent.Store

  setup do
    dir = tmp_dir("intent-store")
    {:ok, dir: dir, pid: elem(Store.start_link(dir: dir, name: nil), 1)}
  end

  defp lines(dir, file), do: dir |> Path.join(file) |> File.read!() |> String.split("\n", trim: true)

  test "own change lands in outbox and cache with private modes", %{dir: dir, pid: pid} do
    c = change()
    assert :ok = Store.append_local(pid, c)
    assert length(lines(dir, "outbox.ndjson")) == 1
    assert length(lines(dir, "changes.ndjson")) == 1
    assert File.stat!(Path.join(dir, "outbox.ndjson")).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700
  end

  test "remote duplicates are written once and never reach the outbox", %{dir: dir, pid: pid} do
    c = change()
    assert {:ok, 1} = Store.append_remote(pid, [c, c], cursor: 9)
    assert {:ok, 0} = Store.append_remote(pid, [c])
    assert length(Store.changes(pid)) == 1
    assert length(lines(dir, "changes.ndjson")) == 1
    refute File.exists?(Path.join(dir, "outbox.ndjson"))
    assert Store.pull_cursor(pid) == 9
  end

  test "restart reloads changes and cursor", %{dir: dir, pid: pid} do
    Store.append_remote(pid, [change()], cursor: 4)
    {:ok, again} = Store.start_link(dir: dir, name: nil)
    assert Store.changes(again) == Store.changes(pid)
    assert Store.pull_cursor(again) == 4
  end

  test "a torn last line is skipped, counted and left in place", %{dir: dir, pid: pid} do
    Store.append_local(pid, change())
    File.write!(Path.join(dir, "changes.ndjson"), ~s({"change_id":"x"), [:append])
    before = File.read!(Path.join(dir, "changes.ndjson"))
    {:ok, again} = Store.start_link(dir: dir, name: nil)
    assert length(Store.changes(again)) == 1
    assert Store.skipped(again) == 1
    assert File.read!(Path.join(dir, "changes.ndjson")) == before
  end

  test "ack removes only the confirmed ids from the outbox", %{dir: dir, pid: pid} do
    [a, b] = [change(), change()]
    Store.append_local(pid, a)
    Store.append_local(pid, b)
    assert :ok = Store.ack_outbox(pid, [a.change_id])
    assert Store.outbox(pid) == [b]
    assert length(lines(dir, "outbox.ndjson")) == 1
    assert length(lines(dir, "changes.ndjson")) == 2
  end
end
