defmodule Aiur.Executor.TakeoverAlert.StoreTest do
  # Registers real named GenServers; serial so concurrent async tests can never
  # race registered-name or state-dir interactions.
  use ExUnit.Case, async: false

  alias Aiur.Executor.TakeoverAlert.Store

  @t0 ~U[2026-01-01 00:00:00Z]

  defp unique_name do
    Module.concat(__MODULE__, :"Store#{System.unique_integer([:positive])}")
  end

  defp tmp_state_dir do
    dir = Path.join(System.tmp_dir!(), "takeover_store_#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(dir)
    # unique_integer values are reused across VM boots, so clean the dir up to
    # prevent a later run's "fresh" store from loading a prior run's state file.
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp start_store(state_dir, name) do
    {:ok, pid} = Store.start_link(name: name, state_dir: state_dir)
    %{pid: pid, name: name}
  end

  describe "observe/4" do
    test "sets a durable anchor on first observation and never resets it" do
      {dir, name} = {tmp_state_dir(), unique_name()}
      start_store(dir, name)

      assert %{anchor_at: anchor} = Store.observe("101", true, @t0, name)
      assert anchor == @t0

      # A later observation — worker restart, redispatch — must not reset the clock.
      assert %{anchor_at: later} = Store.observe("101", true, DateTime.add(@t0, 3600), name)
      assert later == @t0
    end

    test "counts dispatch/restart episodes via live-owner transitions" do
      {dir, name} = {tmp_state_dir(), unique_name()}
      start_store(dir, name)

      assert %{dispatches: 0} = Store.observe("101", false, @t0, name)
      assert %{dispatches: 1} = Store.observe("101", true, @t0, name)
      assert %{dispatches: 1} = Store.observe("101", true, @t0, name)
      assert %{dispatches: 1} = Store.observe("101", false, @t0, name)
      # A fresh live-owner episode (worker restart) increments again.
      assert %{dispatches: 2} = Store.observe("101", true, @t0, name)
    end
  end

  describe "record_alert/3 and record_pr/3" do
    test "records the last alert time and caches PR evidence with a checked timestamp" do
      {dir, name} = {tmp_state_dir(), unique_name()}
      start_store(dir, name)

      Store.observe("101", true, @t0, name)

      assert %{last_alert_at: nil} = Store.record("101", name)
      assert %{last_alert_at: alerted_at} = Store.record_alert("101", DateTime.add(@t0, 8 * 3600), name)
      assert alerted_at == DateTime.add(@t0, 8 * 3600)

      pr = %{number: 5, created_at: @t0, pushed_at: @t0, mergeable_state: "clean", ci_state: "success"}
      assert %{pr: stored, pr_checked_at: checked} = Store.record_pr("101", pr, DateTime.add(@t0, 9 * 3600), name)
      assert stored.number == 5
      assert stored.refreshed_at == DateTime.add(@t0, 9 * 3600)
      assert checked == DateTime.add(@t0, 9 * 3600)
    end

    test "a checked-but-no-PR result is remembered so callers do not re-fetch" do
      {dir, name} = {tmp_state_dir(), unique_name()}
      start_store(dir, name)

      Store.observe("101", true, @t0, name)
      assert %{pr: nil, pr_checked_at: checked} = Store.record_pr("101", nil, @t0, name)
      assert checked == @t0
    end

    test "tracks the last seen time and lists tracked identifiers" do
      {dir, name} = {tmp_state_dir(), unique_name()}
      start_store(dir, name)

      assert Store.identifiers(name) == []

      Store.observe("101", true, @t0, name)
      Store.observe("202", false, @t0, name)

      assert Store.identifiers(name) |> Enum.sort() == ["101", "202"]
      assert Store.last_seen_at("101", name) == @t0
      assert Store.last_seen_at("404", name) == nil
    end
  end

  describe "forget/2" do
    test "reports whether an alert was active and removes the record" do
      {dir, name} = {tmp_state_dir(), unique_name()}
      start_store(dir, name)

      Store.observe("101", true, @t0, name)
      assert {:ok, false} = Store.forget("101", name)
      assert Store.record("101", name) == nil

      Store.observe("101", true, @t0, name)
      Store.record_alert("101", @t0, name)
      assert {:ok, true} = Store.forget("101", name)
      assert Store.record("101", name) == nil
    end
  end

  describe "restart persistence" do
    test "anchor, last alert, dispatch count and PR evidence survive a daemon restart" do
      dir = tmp_state_dir()
      name = unique_name()
      start_store(dir, name)

      Store.observe("101", true, @t0, name)
      Store.observe("101", true, DateTime.add(@t0, 3600), name)
      Store.record_alert("101", DateTime.add(@t0, 8 * 3600), name)
      Store.record_pr("101", %{number: 7, created_at: @t0}, DateTime.add(@t0, 9 * 3600), name)

      # Simulate a daemon restart: stop the process and boot a fresh one over the
      # same state directory.
      GenServer.stop(name)

      start_store(dir, name)

      assert %{
               anchor_at: anchor,
               last_alert_at: last_alert,
               dispatches: 1,
               pr: %{number: 7}
             } = Store.record("101", name)

      assert anchor == @t0
      assert last_alert == DateTime.add(@t0, 8 * 3600)
    end

    test "a fresh store without prior state starts empty" do
      dir = tmp_state_dir()
      name = unique_name()
      start_store(dir, name)
      assert Store.record("999", name) == nil
    end
  end
end
