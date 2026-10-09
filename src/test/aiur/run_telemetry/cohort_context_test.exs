defmodule Aiur.RunTelemetry.CohortContextTest do
  use ExUnit.Case, async: false
  alias Aiur.Config.Schema.Observability
  alias Aiur.Orchestrator.TelemetryCohort
  alias Aiur.RunTelemetry.{Dataset, Lifecycle, RunContext, Summaries, Writer}

  setup do
    root = Aiur.TestSupport.tmp_root!("cohort-context")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "canonical effective hashes exclude secrets and refreshes and isolate agent changes", %{root: root} do
    settings = %{agent: %{max_concurrent_agents: 2, api_key: "a"}, observability: %{refresh_ms: 1}, tracker: %{kind: "github"}}
    opts = [stamp_path: Path.join(root, "missing"), vsn: "test"]
    original = RunContext.build(settings, opts)
    same = RunContext.build(%{settings | agent: %{max_concurrent_agents: 2, api_key: "b"}, observability: %{refresh_ms: 2}}, opts)
    assert original.config_hash == same.config_hash
    changed = RunContext.build(put_in(settings, [:agent, :max_concurrent_agents], 3), opts)
    refute changed.config_hash == original.config_hash
    assert changed.config_section_hashes["agent"] != original.config_section_hashes["agent"]
    assert Map.delete(changed.config_section_hashes, "agent") == Map.delete(original.config_section_hashes, "agent")
    assert original.build_sha == "unknown"
    stamp = Path.join(root, "stamp")
    File.write!(stamp, "source_sha=abc\npackage_version=1-nightly\nrepo_root=private\n")
    context = RunContext.build(settings, stamp_path: stamp, vsn: "test")
    assert context.build_sha == "abc"
    assert context.package_version == "1-nightly"
    assert context.aiur_vsn == "test"
    refute Map.has_key?(context, :settings)
  end

  test "boot, config broadcasts and segment rolls persist context", %{root: root} do
    {:ok, settings} = Agent.start_link(fn -> %{agent: %{max_concurrent_agents: 2}} end)
    builder = fn -> RunContext.build(Agent.get(settings, & &1)) end
    path = Path.join(root, "telemetry.ndjson")
    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "cohort", context_builder: builder, retention: [max_bytes: 20_000, prune_interval_bytes: 1])
    Writer.flush(writer)
    [restart, context] = records(path)
    assert {restart["kind"], restart["sequence"]} == {"restart", 1}
    assert {context["kind"], context["sequence"]} == {"run_context", 2}
    Phoenix.PubSub.broadcast(Aiur.PubSub, "workflow_store:configuration", {:workflow_config_updated, 1})
    :sys.get_state(writer)
    assert length(records(path)) == 2
    Agent.update(settings, &put_in(&1, [:agent, :max_concurrent_agents], 3))
    send(writer, {:workflow_config_updated, 2})
    Writer.flush(writer)
    assert length(records(path)) == 3
    updated = List.last(records(path))["attributes"]
    refute updated["config_hash"] == context["attributes"]["config_hash"]
    Writer.record(writer, :resource, %{actor: "daemon", padding: String.duplicate("x", 21_000)})
    Writer.flush(writer)
    carried = records(path) |> Enum.filter(&(&1["kind"] == "run_context")) |> List.last()
    assert carried["attributes"]["segment_continuation"] == "carried"
    assert carried["attributes"]["config_hash"] == updated["config_hash"]
    GenServer.stop(writer)
  end

  test "dispatch cohorts resolve pins and fail open on feature timeout", %{root: _root} do
    issue = %Aiur.Issue{
      identifier: "3794",
      selected_backend: "codex",
      selected_model: "test-model",
      labels: ["experiment:x", "bug", "model:high"],
      blocked_by: [%{identifier: "3755"}, %{identifier: "3763"}]
    }

    parent = self()

    server =
      spawn(fn ->
        receive do
          _ ->
            send(parent, :feature_lookup)

            receive do
              :stop -> :ok
            end
        end
      end)

    on_exit(fn -> Process.exit(server, :kill) end)
    fields = TelemetryCohort.attempt_fields(issue, server: server, timeout: 1)
    assert_received :feature_lookup
    assert fields.backend == "codex"
    assert fields.model == "test-model"
    assert fields.effort == "high"
    assert fields.tags == ["experiment:x"]
    assert fields.blockers == ["3755", "3763"]
    assert fields.feature == nil
    assert fields.epic == nil
    assert fields.start_mode == "normal"

    owner_server =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:read, {:owner, 3794}}} -> GenServer.reply(from, {:ok, %{feature: "capture", epic: 3774}})
        end
      end)

    owned = TelemetryCohort.attempt_fields(issue, server: owner_server)
    assert {owned.feature, owned.epic} == {"capture", 3774}
    recorder = fn :lifecycle, attrs, _ -> send(self(), {:record, attrs}) end
    Lifecycle.record("3794", "attempt", :dispatch, :point, Map.put(fields, :cause, ["private"]), recorder: recorder)
    assert_received {:record, attrs}
    assert attrs.tags == ["experiment:x"]
    assert attrs.feature == nil
    assert attrs.cause == "unknown"
    Lifecycle.record("3794", "attempt", :dispatch, :point, %{tags: List.duplicate(String.duplicate("x", 70), 21), blockers: [3755]}, recorder: recorder)
    assert_received {:record, bounded}
    assert length(bounded.tags) == 20
    assert Enum.all?(bounded.tags, &(String.length(&1) == 64))
    assert bounded.blockers == ["3755"]
  end

  test "schema validates capture tags and defaults label prefixes" do
    assert Observability.changeset(%Observability{}, %{}).valid?
    assert %Observability{}.capture_label_prefixes == ["experiment:", "cohort:", "feature:"]
    refute Observability.changeset(%Observability{}, %{capture_tags: "invalid"}).valid?
    refute Observability.changeset(%Observability{}, %{capture_tags: Map.new(1..21, &{to_string(&1), "x"})}).valid?
    refute Observability.changeset(%Observability{}, %{capture_tags: %{x: 1}}).valid?
    assert Observability.changeset(%Observability{}, %{capture_tags: %{"variant" => "B"}}).valid?
  end

  test "Elixir reducer keeps v3 cohorts and accepts v2", %{root: root} do
    path = Path.join(root, "telemetry.ndjson")

    records = [
      envelope(2, "restart", 1, %{event: "daemon_restart"}),
      envelope(3, "run_context", 2, %{config_hash: "hash"}),
      envelope(3, "lifecycle", 3, %{
        ticket: "3794",
        event: "dispatch",
        boundary: "point",
        backend: "codex",
        model: "m",
        effort: "high",
        feature: nil,
        epic: 3774,
        tags: ["experiment:x"],
        blockers: ["3755"],
        start_mode: "normal"
      })
    ]

    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")
    assert {:ok, dataset} = Dataset.build([path])
    assert dataset.warnings == []
    assert length(dataset.run_contexts) == 1
    assert Dataset.filter(dataset, boot_id: "cohort").run_contexts == dataset.run_contexts
    assert Dataset.merge([dataset]).run_contexts == dataset.run_contexts
    assert {:ok, decoded} = Summaries.decode_summary(Jason.encode!(dataset))
    assert decoded.run_contexts == dataset.run_contexts
    [event] = dataset.tickets["3794"].events

    assert {event.backend, event.model, event.effort, event.feature, event.epic, event.tags, event.blockers, event.start_mode} ==
             {"codex", "m", "high", nil, 3774, ["experiment:x"], ["3755"], "normal"}
  end

  defp envelope(version, kind, seq, attributes),
    do: %{schema_version: version, kind: kind, sequence: seq, boot_id: "cohort", record_id: "cohort:#{seq}", timestamp: "2026-10-09T00:00:00Z", attributes: attributes}

  defp records(path), do: path |> File.stream!() |> Enum.map(&Jason.decode!/1)
end
