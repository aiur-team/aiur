defmodule Aiur.RunTelemetry.SummariesTest do
  use ExUnit.Case, async: false

  alias Aiur.RunTelemetry.Dataset
  alias Aiur.RunTelemetry.Summaries
  alias AiurWeb.OperatorControlCenter.Analytics.Presenter

  @fixtures Path.expand("../../fixtures/analytics", __DIR__)
  # A single-file fixture represents the live boot; prior boots come from
  # materialized summaries in the state node.
  @telemetry_fixtures Path.expand("../../fixtures/run_telemetry/session-b/telemetry.ndjson", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-summaries-#{System.unique_integer([:positive])}")
    Application.put_env(:aiur, :repo_base_root, root)
    Application.put_env(:aiur, :analytics_repo, "aiur-team/aiur")
    # Pin the "live" boot id so the current-boot raw read is deterministic.
    prior_run_id = :persistent_term.get({Aiur.Boot, :run_id}, :unset)
    :persistent_term.put({Aiur.Boot, :run_id}, "boot-b")

    on_exit(fn ->
      File.rm_rf!(root)
      restore_run_id(prior_run_id)
    end)

    :ok
  end

  defp restore_run_id(:unset), do: :persistent_term.erase({Aiur.Boot, :run_id})
  defp restore_run_id(value), do: :persistent_term.put({Aiur.Boot, :run_id}, value)

  defp seed_state_node do
    node = Summaries.state_node()
    target = Path.join(node, "analytics/runs/boot-a")
    File.mkdir_p!(target)
    File.cp!(Path.join(@fixtures, "runs/boot-a/run-summary.json"), Path.join(target, "run-summary.json"))
    node
  end

  describe "paths" do
    test "resolves the state-node analytics layout beside builds/", %{} do
      node = Summaries.state_node()
      assert node |> Path.basename() |> Path.basename() == "aiur"
      assert Summaries.analytics_dir() == Path.join(node, "analytics")
      assert Summaries.runs_dir() == Path.join(node, "analytics/runs")
      assert Summaries.builds_dir() == Path.join(node, "builds")
      assert Summaries.run_summary_path("boot-a") == Path.join(node, "analytics/runs/boot-a/run-summary.json")
      assert Summaries.build_summary_path("test-build") == Path.join(node, "builds/test-build/build-summary.json")
    end
  end

  describe "decode_summary/1" do
    test "decodes a Python-materialized run summary into the dataset shape" do
      body = File.read!(Path.join(@fixtures, "runs/boot-a/run-summary.json"))
      assert {:ok, dataset} = Summaries.decode_summary(body)

      assert Enum.map(dataset.records, & &1.boot_id) |> Enum.uniq() == ["boot-a"]
      assert Map.keys(dataset.actors) |> Enum.sort() == ["_daemon", "_operator", "ticket:930", "ticket:931"]
      assert Map.keys(dataset.tickets) |> Enum.sort() == ["930", "931"]

      # The shape must be consumable by the analytics model pipeline.
      opts = [cap: 4, cores: 4, host_mem_bytes: 1_000_000_000, buckets: 10]
      model = Presenter.model(dataset, opts)
      assert model.available? == true
      assert Enum.map(model.tickets, & &1.id) |> Enum.sort() == ["930", "931"]
    end

    test "rejects malformed JSON" do
      assert {:error, :invalid_summary} = Summaries.decode_summary("not json")
    end

    test "rejects a summary whose record timestamp is not ISO-8601" do
      body = Jason.encode!(%{"records" => [Map.put(lifecycle_record("review_pause", 0), "timestamp", "whenever")]})
      assert {:error, :invalid_summary} = Summaries.decode_summary(body)
    end

    # Review P1: `Dataset.merge/1` re-reduces the union of records, and the
    # review-finding path does `DateTime.add/3` on a record's timestamp. A
    # summary-decoded record that kept its ISO string there crashes the whole
    # :cross pane, which the Presenter swallows into {:unavailable, :error}.
    test "decoded records re-reduce through Dataset.merge, including review findings" do
      body =
        Jason.encode!(%{
          "records" => [
            lifecycle_record("review_pause", 0),
            lifecycle_record("comment_received", 60)
          ]
        })

      assert {:ok, dataset} = Summaries.decode_summary(body)
      merged = Dataset.merge([dataset])

      assert %DateTime{} = hd(dataset.records).timestamp

      assert [finding] = merged.findings
      assert finding.type == "review_pause_resume"
      assert finding.ticket == "930"
    end
  end

  describe "materialization" do
    test "reduce_command resolves the reduce script and passes state node + telemetry" do
      with_tmp_reduce(fn dir ->
        assert {:ok, {script, args}} = Summaries.reduce_command(reduce_dir: dir)
        assert Path.basename(script) == "reduce"
        assert "--state-node" in args
        assert "--all-builds" in args
        assert Summaries.state_node() in args
      end)
    end

    test "materialize fails open when no reduce dir is available" do
      assert {:error, :reduce_unavailable} = Summaries.materialize(reduce_dir: "/nonexistent/analytics")
    end

    test "materialize returns the reduce output on success" do
      with_tmp_reduce(fn dir ->
        script = Path.join(dir, "reduce")
        File.write!(script, "#!/usr/bin/env bash\necho materialized\n")
        File.chmod!(script, 0o755)
        assert {:ok, output} = Summaries.materialize(reduce_dir: dir)
        assert output =~ "materialized"
      end)
    end
  end

  describe "reading" do
    test "load_dataset reads a materialized run summary" do
      seed_state_node()
      assert {:ok, dataset} = Summaries.load_dataset("boot-a")
      assert Map.has_key?(dataset.tickets, "930")

      assert {:error, :missing} = Summaries.load_dataset("does-not-exist")
    end

    test "summary_boot_ids lists materialized boot dirs" do
      seed_state_node()
      assert "boot-a" in Summaries.summary_boot_ids()
    end

    test "load_prior_datasets excludes the live boot" do
      seed_state_node()
      assert [dataset] = Summaries.load_prior_datasets("other-boot")
      assert Enum.any?(dataset.records, &(&1.boot_id == "boot-a"))
      assert [] = Summaries.load_prior_datasets("boot-a")
    end
  end

  describe "presenter :cross session" do
    test "merges the live boot (raw tail) with prior boots from summaries" do
      seed_state_node()

      # The live boot is the single raw file (boot-b); boot-a is served from its
      # materialized summary. The cross view must serve boot-a from the summary
      # and boot-b from raw without a full parse.
      assert {:ok, model} =
               Presenter.load(
                 session: :cross,
                 telemetry_file: @telemetry_fixtures,
                 cap: 4,
                 cores: 4,
                 host_mem_bytes: 1_000_000_000
               )

      assert model.available?
      assert model.kpis.sessions == 2
      assert Enum.map(model.tickets, & &1.id) |> Enum.sort() == ["930", "931"]
      assert model.kpis.done >= 1
    end

    # Review P2: the assertions above (session count, ticket-id set, done count)
    # all survive a last-wins map merge, so none of them detects the collision.
    # `_daemon` is sampled in boot-a (summary) and again in boot-b (live raw); a
    # last-wins merge keeps only boot-a's actor entry and the live boot's sample
    # disappears from the resource chart. Daemon CPU folds into `exec_cpu`, so a
    # non-zero bucket after boot-a's last record is the collision-sensitive proof
    # that both boots' samples survived.
    test "the live boot's daemon samples survive the merge with a prior boot's summary" do
      seed_state_node()

      assert {:ok, model} =
               Presenter.load(
                 session: :cross,
                 telemetry_file: @telemetry_fixtures,
                 cap: 4,
                 cores: 4,
                 host_mem_bytes: 1_000_000_000
               )

      # boot-a's newest record is pr_merged at 00:00:13Z; boot-b's daemon sample
      # is at 00:01:01Z. Anything charted after the boot-a boundary can only have
      # come from the live boot.
      boot_a_end_ms = 1_783_728_013_000

      assert Enum.any?(model.series, &(&1.t_ms > boot_a_end_ms and &1.exec_cpu > 0)),
             "expected the live boot's _daemon sample to appear after the prior boot's last record"

      # And the prior boot's own samples are still charted — the union must not
      # trade one boot's data for the other's.
      assert Enum.any?(model.series, &(&1.t_ms <= boot_a_end_ms and &1.exec_cpu > 0))
    end

    test "falls back to a full raw parse when no summaries exist yet" do
      # No summaries seeded: :cross must degrade to the historical full parse.
      assert {:ok, model} =
               Presenter.load(
                 session: :cross,
                 telemetry_file: @telemetry_fixtures,
                 cap: 4,
                 cores: 4,
                 host_mem_bytes: 1_000_000_000
               )

      assert model.available?
      assert model.kpis.sessions == 1
    end
  end

  defp lifecycle_record(event, offset_seconds) do
    timestamp =
      DateTime.add(~U[2026-07-09 00:00:00Z], offset_seconds, :second) |> DateTime.to_iso8601()

    %{
      "schema_version" => 1,
      "kind" => "lifecycle",
      "timestamp" => timestamp,
      "boot_id" => "boot-a",
      "sequence" => offset_seconds,
      "record_id" => "boot-a:#{event}:#{offset_seconds}",
      "attributes" => %{
        "ticket" => "930",
        "event" => event,
        "boundary" => "point",
        "source_id" => "comment-1"
      }
    }
  end

  defp with_tmp_reduce(fun) do
    dir = Path.join(System.tmp_dir!(), "aiur-reduce-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    script = Path.join(dir, "reduce")
    File.write!(script, "#!/usr/bin/env bash\nprintf 'ok\\n'\n")
    File.chmod!(script, 0o755)
    on_exit(fn -> File.rm_rf!(dir) end)
    fun.(dir)
  end
end
