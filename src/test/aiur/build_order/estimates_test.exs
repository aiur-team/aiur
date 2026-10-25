defmodule Aiur.BuildOrder.EstimatesTest do
  use ExUnit.Case, async: false
  import Bitwise
  alias Aiur.BuildOrder.Estimates
  alias Aiur.BuildOrder.ProviderHealth

  setup do
    dir = Aiur.TestSupport.tmp_root!("estimates")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")
    %{dir: dir, path: Path.join(dir, "estimates.json"), opts: [name: name, state_dir: dir, repository: "acme/app"], read: [server: name]}
  end

  defp start(c, extra \\ []), do: start_supervised!({Estimates, Keyword.merge(c.opts, extra)})

  test "table defaults and unknown estimates preserve uncertainty" do
    assert Enum.map(1..5, &Estimates.default_hours/1) == [1, 2, 4, 7, 11]
    assert Estimates.resolve(%{num: 5, cx: nil}, %{}) == %{est: nil, override: nil}
    assert Estimates.resolve(%{num: 5, cx: 3}, :unavailable) == %{est: nil, override: nil}
    override = %{hours: 6, reason: "design", by: "cli:planner", at: DateTime.utc_now()}
    assert %{est: nil, override: %{hours: 6, at: at}} = Estimates.resolve(%{num: 5, cx: nil}, %{5 => override})
    assert at == DateTime.to_unix(override.at, :millisecond)
    assert Estimates.resolve(%{num: nil, cx: 2}, %{5 => override}) == %{est: 2, override: nil}
  end

  test "put, clear, and restart preserve records, journal and private permissions", c do
    start(c)
    assert {:ok, record} = Estimates.put(5, 7.25, "  design rounds  ", "cli:planner", c.read)
    assert record.reason == "design rounds"
    assert {:ok, %{override: ^record, journal: [%{op: :set, hours: 7.25}]}} = Estimates.get(5, c.read)
    assert (File.stat!(c.path).mode &&& 0o777) == 0o600
    stop_supervised!(Estimates)
    start(c)
    assert {:ok, %{5 => ^record}} = Estimates.overrides(c.read)
    assert {:ok, :cleared} = Estimates.clear(5, "replanned", "cli:planner", c.read)
    assert {:ok, %{override: nil, journal: [%{op: :clear, hours: nil}, %{op: :set}]}} = Estimates.get(5, c.read)
    assert {:ok, :absent} = Estimates.clear(5, "already clear", "cli:planner", c.read)
    assert Estimates.health(c.read).generation == 2
  end

  test "daemon rejects every invalid input without touching the file", c do
    start(c)

    for hours <- [0, -1, 2.3, 1000, "3"] do
      assert {:error, :invalid_hours} = Estimates.put(5, hours, "reason", "cli:p", c.read)
    end

    for reason <- ["", " ", "line\nbreak", "tab\tbreak", String.duplicate("x", 501)] do
      assert {:error, :invalid_reason} = Estimates.put(5, 1, reason, "cli:p", c.read)
    end

    assert {:error, :invalid_by} = Estimates.put(5, 1, "reason", "bad actor", c.read)
    assert {:error, :invalid_id} = Estimates.put("pack:5", 1, "reason", "cli:p", c.read)
    refute File.exists?(c.path)
  end

  test "corruption is quarantined, and reads and writes refuse", c do
    File.write!(c.path, "{not json")
    start(c)
    assert {:error, %ProviderHealth{state: :unavailable, failure: :estimates_corrupt}} = Estimates.overrides(c.read)
    assert length(Path.wildcard(c.path <> ".corrupt-*")) == 1
    assert {:error, :estimates_unavailable} = Estimates.put(5, 1, "reason", "cli:p", c.read)
    refute File.exists?(c.path)
    stop_supervised!(Estimates)
    start(c)
    assert Estimates.health(c.read).failure == :estimates_corrupt
    assert {:error, :estimates_unavailable} = Estimates.put(5, 1, "reason", "cli:p", c.read)
  end

  test "malformed persisted records are quarantined as corruption", c do
    record = %{hours: 3, reason: "reason", by: "cli:p", at: 42}
    File.write!(c.path, Jason.encode!(%{version: 1, repository: "acme/app", generation: 1, tickets: %{5 => %{override: record, journal: []}}}))
    start(c)
    assert Estimates.health(c.read).failure == :estimates_corrupt
    assert length(Path.wildcard(c.path <> ".corrupt-*")) == 1
  end

  test "unresolvable state directories refuse reads and writes", c do
    start(c, state_dir: nil)
    assert Estimates.health(c.read).failure == :state_dir_unavailable
    assert {:error, :estimates_unavailable} = Estimates.clear(5, "reason", "cli:p", c.read)
  end

  test "future versions and repository mismatches are preserved", c do
    for {data, failure} <- [{%{version: 2}, :version_unsupported}, {%{version: 1, repository: "other/repo"}, :repository_mismatch}] do
      bytes = Jason.encode!(data)
      File.write!(c.path, bytes)
      start(c)
      assert Estimates.health(c.read).failure == failure
      assert File.read!(c.path) == bytes
      stop_supervised!(Estimates)
    end
  end

  test "symlinks, directories and oversized stores are unsafe", c do
    target = Path.join(c.dir, "target")
    File.write!(target, "untouched")
    File.ln_s!(target, c.path)
    start(c)
    assert Estimates.health(c.read).failure == :estimates_unsafe_path
    assert File.read!(target) == "untouched"
    stop_supervised!(Estimates)
    File.rm!(c.path)
    File.mkdir!(c.path)
    start(c)
    assert Estimates.health(c.read).failure == :estimates_unsafe_path
    stop_supervised!(Estimates)
    File.rmdir!(c.path)
    File.write!(c.path, String.duplicate("x", 1_048_577))
    start(c)
    assert Estimates.health(c.read).failure == :estimates_unsafe_path
  end

  test "failed write leaves the previous override and journal untouched", c do
    start(c)
    assert {:ok, record} = Estimates.put(5, 3, "original", "cli:p", c.read)
    stop_supervised!(Estimates)
    start(c, writer: fn _, _, _ -> {:error, :enospc} end)
    assert {:error, :write_failed} = Estimates.put(5, 9, "new", "cli:p", c.read)
    assert {:ok, %{override: ^record, journal: [%{hours: 3}]}} = Estimates.get(5, c.read)
    assert Estimates.health(c.read).generation == 1
  end

  test "concurrent writers retain both entries and journal is capped at twenty", c do
    start(c)
    tasks = for hours <- [3, 9], do: Task.async(fn -> Estimates.put(5, hours, "parallel", "cli:p", c.read) end)
    assert Enum.all?(Enum.map(tasks, &Task.await/1), &match?({:ok, _}, &1))
    assert {:ok, %{override: override, journal: [latest, previous]}} = Estimates.get(5, c.read)
    assert Map.delete(latest, :op) == override
    assert Enum.sort([latest.hours, previous.hours]) == [3, 9]
    for hours <- 1..25, do: assert({:ok, _} = Estimates.put(5, hours, "sequence", "cli:p", c.read))
    assert {:ok, %{journal: journal}} = Estimates.get(5, c.read)
    assert Enum.map(journal, & &1.hours) == Enum.to_list(25..6//-1)
  end

  test "unchanged values journal provenance without changing generation", c do
    start(c)
    assert {:ok, _} = Estimates.put(5, 3, "reason", "cli:first", c.read)
    assert {:ok, _} = Estimates.put(5, 3, "reason", "cli:second", c.read)
    assert Estimates.health(c.read).generation == 1
    assert {:ok, %{override: %{by: "cli:second"}, journal: [_, _]}} = Estimates.get(5, c.read)
  end

  test "startup signals an already subscribed index after store recovery", c do
    start(c)
    assert {:ok, _} = Estimates.put(5, 3, "persisted", "cli:p", c.read)
    stop_supervised!(Estimates)
    :ok = Estimates.subscribe()
    start(c)
    assert {:ok, %{5 => %{hours: 3}}} = Estimates.overrides(c.read)
    assert_received {:build_estimates_changed, %{generation: 1, changed: []}}
  end

  test "changed values publish the committed generation", c do
    start(c)
    :ok = Estimates.subscribe()
    assert {:ok, _} = Estimates.put(5, 3, "reason", "cli:p", c.read)
    assert_received {:build_estimates_changed, %{generation: 1, changed: [5]}}
    assert {:ok, %{overrides: %{5 => %{hours: 3}}, health: %{generation: 1}}} = Estimates.snapshot(c.read)
  end
end
