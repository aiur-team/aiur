defmodule Aiur.IdleSnapshotHotPathsTest do
  use Aiur.TestSupport

  alias Aiur.AlertLedger
  alias Aiur.BuildOrder.Features.{RootImport, RootImportMapping}
  alias Aiur.CodingAgent
  alias Aiur.CodingAgent.{LabelClassification, Registry}
  alias Aiur.GitHub.{AccessSettings, Transport}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Issue
  alias Aiur.Jsonl
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport.SnapshotPayload
  alias Aiur.SystemCgroup

  @moduletag :tmp_dir

  test "snapshot enumerates the registry once regardless of issue count" do
    for count <- [1, 50] do
      issues =
        Map.new(1..count, fn n ->
          {"#{n}", %Issue{id: "#{n}", identifier: "HOT-#{n}", state: "todo", labels: ["model:codex", "complexity:3"]}}
        end)

      {payload, calls} =
        measured_calls({Registry, :entries, 0}, fn ->
          SnapshotPayload.snapshot_payload(%State{last_polled_issues: issues, candidate_snapshot_fresh?: true})
        end)

      assert length(payload.idle) == count
      assert Enum.all?(payload.idle, &(&1.backend == "codex" and &1.complexity == 3 and &1.agent_family == "codex"))
      assert calls <= 1
    end
  end

  test "complexity classification uses no regex and reuses unchanged labels" do
    {levels, calls} =
      measured_calls({Regex, :run, 2}, fn ->
        for labels <- [["complexity:3"], ["complexity:3"], ["complexity:5", "complexity:3"], ["complexity:0007"], ["complexity:+3", "complexity:3x"], []] do
          CodingAgent.complexity_level(%Issue{labels: labels})
        end
      end)

    assert levels == [3, 3, 5, 7, nil, nil]
    assert calls == 0

    {levels, calls} =
      measured_calls({Integer, :parse, 1}, fn ->
        issue = %Issue{labels: ["complexity:0099"]}
        {CodingAgent.complexity_level(issue), CodingAgent.complexity_level(issue), CodingAgent.complexity_level(%{issue | labels: ["complexity:0098"]})}
      end)

    assert levels == {99, 99, 98}
    assert calls == 2
  end

  test "prepared classifications survive a fresh projection worker and invalidate changed labels" do
    {result, calls} =
      measured_calls({LabelClassification, :classify, 1}, fn ->
        issue = %Issue{labels: ["complexity:0099"]}
        first = CodingAgent.snapshot_classifications([issue, issue])
        next = CodingAgent.snapshot_classifications([issue, %{issue | labels: ["complexity:0098"]}])
        level = Task.async(fn -> CodingAgent.with_classification_cache(next, fn -> CodingAgent.complexity_level(issue) end) end) |> Task.await()
        {first, next, level}
      end)

    assert result == {%{["complexity:0099"] => 99}, %{["complexity:0099"] => 99, ["complexity:0098"] => 98}, 99}
    assert calls == 2
  end

  test "snapshot registry scope cleans up after nested failures" do
    {_result, calls} =
      measured_calls({Registry, :entries, 0}, fn ->
        assert_raise RuntimeError, "failure", fn ->
          CodingAgent.with_snapshot(fn -> CodingAgent.with_snapshot(fn -> raise "failure" end) end)
        end

        CodingAgent.with_snapshot(fn -> CodingAgent.backends() end)
        CodingAgent.backends()
      end)

    assert calls == 3
  end

  test "cgroup root is discovered once and overrides remain live", %{tmp_dir: root} do
    key = {SystemCgroup, :root}
    previous = :persistent_term.get(key, :unset)
    override = Application.get_env(:aiur, :cgroup_root_override)
    :persistent_term.erase(key)

    on_exit(fn ->
      if previous == :unset, do: :persistent_term.erase(key), else: :persistent_term.put(key, previous)
      Application.put_env(:aiur, :cgroup_root_override, override)
    end)

    File.write!(Path.join(root, "cpu.max"), "200000 100000")
    assert SystemCgroup.root(fn -> root end) == root
    assert SystemCgroup.root(fn -> flunk("rediscovered cgroup") end) == root
    Application.delete_env(:aiur, :cgroup_root_override)
    assert SystemCgroup.cpu_quota() == 2.0
    Application.put_env(:aiur, :cgroup_root_override, Path.join(root, "missing"))
    assert SystemCgroup.cpu_quota() == :unavailable
  end

  test "repository settings and parsed identity expire when the configuration changes" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "one/repo")

    {result, calls} =
      measured_calls({Transport, :parse_repo_value, 1}, fn ->
        first = Transport.parse_repo()
        same = Transport.parse_repo()
        write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "two/repo")
        {first, same, Transport.parse_repo()}
      end)

    assert result == {{:ok, {"one", "repo"}}, {:ok, {"one", "repo"}}, {:ok, {"two", "repo"}}}
    assert calls == 2
  end

  test "access settings reuse stable fields but refresh after config changes" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "one/repo")

    {repos, calls} =
      measured_calls({GitHubConfig, :repo, 1}, fn ->
        first = AccessSettings.settings().repo
        same = AccessSettings.settings().repo
        write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "two/repo")
        {first, same, AccessSettings.settings().repo}
      end)

    assert repos == {"one/repo", "one/repo", "two/repo"}
    assert calls == 2
  end

  test "root join mapping is indexed instead of rescanned per member" do
    at = DateTime.utc_now()
    ref = fn n, owner -> %{number: n, owner: owner, repository: "repo"} end
    entries = for n <- 1..100, do: %{ref: ref.(n, "owner"), at: at}
    root = %{number: 1000, labels: ["build-order"], title: "Root", created_at: at, closed_at: :none, sub_issues_added: entries ++ [%{ref: ref.(1, "other"), at: DateTime.add(at, 1)}]}
    rows = Map.new(1..100, &{&1, %{number: &1, labels: [], parent: ref.(1000, "owner")}}) |> Map.put(1000, root)

    {plan, calls} =
      measured_calls({RootImportMapping, :entries, 1}, fn ->
        RootImport.plan(%{rows: rows, repository: "owner/repo", health: %{complete?: true}}, %{features: %{}, owners: %{}, also: %{}}, %{})
      end)

    assert Enum.map(plan.adds, fn {"bo-1000", numbers, "f-bo-1000", ^at} -> numbers end) |> List.flatten() == Enum.to_list(1..100)
    assert calls <= 2
    assert plan.skipped_cross_repo == 1
  end

  test "ledger decodes only appended records and resets after replacement and truncation", %{tmp_dir: root} do
    path = Path.join(root, "alerts.ndjson")
    File.write!(path, "{\"n\":1}\n")

    {result, calls} =
      measured_calls({Jsonl, :decode_line, 1}, fn ->
        first = AlertLedger.read(path)
        same = AlertLedger.read(path)
        File.write!(path, "{\"n\":2}\n", [:append])
        appended = AlertLedger.read(path)
        {first, same, appended}
      end)

    assert result == {[%{"n" => 1}], [%{"n" => 1}], [%{"n" => 1}, %{"n" => 2}]}
    assert calls == 2
    assert AlertLedger.read(path) == [%{"n" => 1}, %{"n" => 2}]
    File.write!(path, "{\"n\":3}\n")
    assert AlertLedger.read(path) == [%{"n" => 3}]
    replacement = Path.join(root, "replacement")
    File.write!(replacement, "{\"n\":4}\n")
    File.rename!(replacement, path)
    assert AlertLedger.read(path) == [%{"n" => 4}]
  end

  test "future regression guard: ledger preserves partial appends and bounded tail semantics", %{tmp_dir: root} do
    path = Path.join(root, "partial.ndjson")
    File.write!(path, "{\"n\":1}\n{\"n\":")
    assert AlertLedger.read(path) == [%{"n" => 1}]
    File.write!(path, "2}\n", [:append])
    assert AlertLedger.read(path) == [%{"n" => 1}, %{"n" => 2}]
    assert AlertLedger.read(path, max_bytes: 9) == [%{"n" => 2}]
    File.write!(path, "{\"n\":3}\n", [:append])
    assert AlertLedger.read(path, max_bytes: 9) == [%{"n" => 3}]
  end

  defp measured_calls({module, _, _} = mfa, fun) do
    Code.ensure_loaded!(module)
    parent = self()

    worker =
      spawn_link(fn ->
        receive do
          :run -> send(parent, {:result, self(), fun.()})
        end

        receive do
          :stop -> :ok
        end
      end)

    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(worker, true, [:call, :set_on_spawn, {:tracer, parent}])

    try do
      send(worker, :run)
      result = receive do: ({:result, ^worker, result} -> result)
      ref = :erlang.trace_delivered(:all)
      receive do: ({:trace_delivered, :all, ^ref} -> :ok)
      {result, count_calls(worker, mfa, 0)}
    after
      :erlang.trace(worker, false, [:call])
      :erlang.trace_pattern(mfa, false, [:local])
      send(worker, :stop)
    end
  end

  defp count_calls(pid, {module, function, arity} = mfa, count) do
    receive do
      {:trace, _traced_pid, :call, {^module, ^function, args}} when length(args) == arity -> count_calls(pid, mfa, count + 1)
    after
      0 -> count
    end
  end
end
