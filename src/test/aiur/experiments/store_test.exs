defmodule Aiur.Experiments.StoreTest do
  use ExUnit.Case, async: false

  alias Aiur.Experiments
  alias Aiur.Experiments.{CapabilityProvider, Journal, Paths, Store}

  setup do
    {:ok, _applications} = Application.ensure_all_started(:phoenix_pubsub)
    root = Path.join(System.tmp_dir!(), "experiments-store-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :experiments_dir)
    failure_key = {Store, :startup_failure}
    previous_failure = :persistent_term.get(failure_key, :disabled)
    Application.put_env(:aiur, :experiments_dir, root)
    unless Process.whereis(Aiur.PubSub), do: start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})

    on_exit(fn ->
      if previous_failure == :disabled, do: :persistent_term.erase(failure_key), else: :persistent_term.put(failure_key, previous_failure)
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp attrs do
    %{
      title: "Delivery change",
      hypothesis: "Faster delivery",
      design: %{kind: "before_after", change: %{type: "manual", ref: "test", time: "2026-10-01T00:00:00Z"}},
      metrics: [%{ref: "delivery-speed/start_to_merge", direction: "decrease"}]
    }
  end

  test "create persists spec, audit and index, broadcasts and deduplicates by key" do
    start_supervised!(Store)
    :ok = Experiments.subscribe()
    {:ok, spec} = Experiments.create(Map.put(attrs(), :key, "release:test"))
    assert_received {:experiments_changed, id}
    assert id == spec.id
    assert File.exists?(Paths.file(id, "spec.json"))
    assert {:ok, stat} = File.stat(Paths.experiment(id))
    assert Bitwise.band(stat.mode, 0o777) == 0o700
    assert [%{"kind" => "created", "schema_version" => 1}] = Experiments.journal(id)
    {:ok, index} = File.read(Path.join(Paths.root(), "index.json"))
    assert [%{"id" => ^id}] = Jason.decode!(index)["experiments"]
    assert {:ok, %{id: ^id, existing: true}} = Experiments.create(Map.put(attrs(), :key, "release:test"))
    assert length(Experiments.journal(id)) == 1
    assert {:ok, second} = Experiments.create(attrs())
    assert second.id == id <> "-2"
  end

  test "amendment records changed metrics and post-registration; status keeps notes" do
    start_supervised!(Store)
    future = put_in(attrs(), [:design, :change, :time], "2099-01-01T00:00:00Z")
    {:ok, spec} = Experiments.create(future)
    assert {:ok, _spec} = Experiments.amend(spec.id, %{notes: "original note"}, "operator")
    assert List.last(Experiments.journal(spec.id))["post_registration"] == false
    assert {:ok, _spec} = Experiments.amend(spec.id, %{registered_at: "2026-10-01T00:00:00Z"}, "operator")
    metrics = [%{ref: "delivery-speed/start_to_merge", direction: "increase"}]
    assert {:ok, _spec} = Experiments.amend(spec.id, %{metrics: metrics}, "analyst")
    entry = List.last(Experiments.journal(spec.id))
    assert entry["post_registration"] == true
    assert entry["diff"]["metrics"]["after"] == [%{"ref" => "delivery-speed/start_to_merge", "direction" => "increase", "primary" => true}]
    assert {:ok, concluded} = Experiments.set_status(spec.id, :concluded, "enough samples", "operator")
    assert concluded.notes == "original note"
    assert List.last(Experiments.journal(spec.id))["reason"] == "enough samples"
    assert {:error, _errors} = Experiments.set_status(spec.id, :invalid, "invalid", "operator")
    assert {:ok, _spec} = Experiments.amend(spec.id, %{notes: "after conclusion"}, "operator")
    assert {:error, :invalid_status_transition} = Experiments.set_status(spec.id, :active, "reopen", "operator")
  end

  test "newer specs and journals refuse mutation without changing bytes" do
    start_supervised!(Store)
    {:ok, spec} = Experiments.create(attrs())
    path = Paths.file(spec.id, "spec.json")
    bytes = File.read!(path) |> Jason.decode!() |> Map.put("schema_version", 2) |> Jason.encode!()
    File.write!(path, bytes)
    assert {:ok, %{read_only?: true}} = Experiments.fetch(spec.id)
    assert {:error, {:newer_version, 2}} = Experiments.amend(spec.id, %{title: "changed"}, "operator")
    assert File.read!(path) == bytes
    {:ok, second} = Experiments.create(attrs())
    journal = Paths.file(second.id, "journal.ndjson")
    File.write!(journal, Jason.encode!(%{schema_version: 2, kind: "future"}) <> "\n", [:append])
    before = File.read!(journal)
    assert {:error, {:newer_version, 2}} = Experiments.amend(second.id, %{title: "changed"}, "operator")
    assert File.read!(journal) == before
  end

  test "listing survives corrupt specs and requests index rebuild", %{root: root} do
    start_supervised!(Store)
    {:ok, first} = Experiments.create(attrs())
    {:ok, second} = Experiments.create(attrs())
    File.write!(Paths.file(second.id, "spec.json"), "{")
    File.rm!(Path.join(root, "index.json"))
    assert {:ok, rows} = Experiments.list()
    assert Enum.any?(rows, &(&1.id == first.id and &1.title == first.title))
    assert %{id: second.id, error: :unreadable} in rows
    :sys.get_state(Store)
    assert File.exists?(Path.join(root, "index.json"))
  end

  test "annotations validate and append, absent writer refuses writes" do
    assert Experiments.child(false) == nil
    assert Experiments.create(attrs()) == {:error, :disabled}
    start_supervised!(Store)
    {:ok, spec} = Experiments.create(attrs())
    assert :ok = Experiments.annotate(spec.id, %{kind: "note", reason: "deploy", at: "2026-10-01T00:00:00Z"}, "operator")
    assert {:ok, %{annotations: [%{"kind" => "note", "actor" => "operator", "schema_version" => 1}]}} = Experiments.fetch(spec.id)
    assert {:error, :invalid_annotation} = Experiments.annotate(spec.id, %{kind: "unknown"}, "operator")
  end

  test "invalid annotation timestamp refuses input and keeps the writer alive" do
    start_supervised!(Store)
    {:ok, spec} = Experiments.create(attrs())
    assert {:error, :invalid_annotation} = Experiments.annotate(spec.id, %{kind: "note", reason: "test", at: 123}, "operator")
    assert {:ok, _spec} = Experiments.amend(spec.id, %{notes: "writer still running"}, "operator")
  end

  test "a reached change line registers creation and later amendments" do
    start_supervised!(Store)
    past = put_in(attrs(), [:design, :change, :time], "1900-01-01T00:00:00Z")
    assert {:ok, spec} = Experiments.create(past)
    assert spec.registered_at == "1900-01-01T00:00:00Z"
    assert {:error, :immutable_field} = Experiments.amend(spec.id, %{registered_at: nil}, "analyst")
    assert {:ok, _updated} = Experiments.amend(spec.id, %{notes: "after the change"}, "analyst")
    assert List.last(Experiments.journal(spec.id))["post_registration"] == true
  end

  test "future annotations and pending transactions make the experiment read-only" do
    start_supervised!(Store)
    {:ok, spec} = Experiments.create(attrs())
    path = Paths.file(spec.id, "annotations.ndjson")
    File.write!(path, Jason.encode!(%{schema_version: 2, kind: "future"}) <> "\n")
    bytes = File.read!(path)
    assert {:ok, %{read_only?: true}} = Experiments.fetch(spec.id)
    assert {:error, {:newer_version, 2}} = Experiments.annotate(spec.id, %{kind: "note", at: "2026-10-01T00:00:00Z", reason: "test"}, "operator")
    assert File.read!(path) == bytes
    {:ok, second} = Experiments.create(attrs())
    pending = Paths.file(second.id, "pending.json")
    File.write!(pending, Jason.encode!(%{schema_version: 2}))
    pending_bytes = File.read!(pending)
    assert {:ok, %{read_only?: true}} = Experiments.fetch(second.id)
    assert {:error, {:newer_version, 2}} = Experiments.amend(second.id, %{title: "changed"}, "operator")
    assert File.read!(pending) == pending_bytes
  end

  test "directory errors surface and unfamiliar future shapes remain readable", %{root: root} do
    start_supervised!(Store)
    {:ok, spec} = Experiments.create(attrs())
    File.write!(Paths.file(spec.id, "spec.json"), Jason.encode!(%{schema_version: 2, design: "future"}))
    assert {:ok, [%{id: id, read_only?: true}]} = Experiments.list()
    assert id == spec.id
    assert {:ok, %{read_only?: true, phase: :unknown}} = Experiments.fetch(spec.id)
    stop_supervised!(Store)
    File.rm_rf!(root)
    File.write!(root, "not a directory")
    assert {:error, :enotdir} = Experiments.list()
  end

  test "a pending-only create retry recovers before matching its key" do
    start_supervised!({Store, journal_writer: fn _path, _entry -> {:error, :injected_failure} end})
    input = Map.put(attrs(), :key, "pending:retry")
    assert {:error, :injected_failure} = Experiments.create(input)
    assert {:ok, [id]} = Paths.ids()
    File.rm!(Paths.file(id, "spec.json"))
    assert {:ok, %{id: ^id, existing: true}} = Experiments.create(input)
    assert {:ok, [row]} = Experiments.list()
    assert row.id == id
    assert [%{"kind" => "created"}] = Experiments.journal(id)
  end

  test "corrupt pending transactions leave the optional child ignored and files untouched", %{root: root} do
    File.mkdir_p!(Path.join(root, "broken"))
    pending = Paths.file("broken", "pending.json")
    File.write!(pending, "{")
    assert Store.start_link() == :ignore
    assert File.read!(pending) == "{"
    assert Experiments.status().store == {:error, :unreadable}
    report = CapabilityProvider.capabilities(%{})
    assert report["experiments"] == %{state: :unavailable, reason: :store_unavailable}
    assert Experiments.create(attrs()) == {:error, :unreadable}
  end

  test "restart reconciles an audit entry appended before an ambiguous failure" do
    append_then_fail = fn path, entry ->
      :ok = Journal.append(path, entry)
      {:error, :injected_failure}
    end

    start_supervised!({Store, journal_writer: append_then_fail})
    assert {:error, :injected_failure} = Experiments.create(attrs())
    stop_supervised!(Store)
    start_supervised!(Store)
    assert {:ok, [row]} = Experiments.list()
    assert [%{"kind" => "created"}] = Experiments.journal(row.id)
    assert {:ok, detail} = Experiments.fetch(row.id)
    assert detail.spec["title"] == "Delivery change"
    refute File.exists?(Paths.file(row.id, "pending.json"))
  end

  test "restart repairs exact audit diff after append failure" do
    start_supervised!({Store, journal_writer: fn _path, _entry -> {:error, :injected_failure} end})
    assert {:error, :injected_failure} = Experiments.create(attrs())
    stop_supervised!(Store)
    start_supervised!(Store)
    assert {:ok, [row]} = Experiments.list()
    assert [%{"kind" => "created"}] = Experiments.journal(row.id)
    stop_supervised!(Store)
    start_supervised!({Store, journal_writer: fn _path, _entry -> {:error, :injected_failure} end})
    assert {:error, :injected_failure} = Experiments.amend(row.id, %{title: "Recovered title"}, "analyst")
    stop_supervised!(Store)
    start_supervised!(Store)
    entry = List.last(Experiments.journal(row.id))
    assert entry["kind"] == "amended"
    assert entry["actor"] == "analyst"
    assert entry["diff"]["title"] == %{"before" => "Delivery change", "after" => "Recovered title"}
    assert length(Experiments.journal(row.id)) == 2
    refute File.exists?(Paths.file(row.id, "pending.json"))
  end
end
