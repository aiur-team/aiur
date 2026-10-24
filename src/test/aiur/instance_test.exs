defmodule Aiur.InstanceTest do
  use Aiur.TestSupport

  alias Aiur.Config.Schema
  alias Aiur.Config.Schema.Instance.Ignore
  alias Aiur.Instance
  alias Aiur.Instance.SweepFilter

  test "instance.ignore parses the three lists and defaults them empty" do
    assert {:ok, default} = Schema.parse(%{})
    assert %Ignore{tickets: [], labels: [], label_prefixes: []} = default.instance.ignore

    assert {:ok, parsed} =
             Schema.parse(%{"instance" => %{"ignore" => %{"tickets" => [4121], "labels" => ["lane:nuc"], "label_prefixes" => ["nuc"]}}})

    assert parsed.instance.ignore == %Ignore{tickets: [4121], labels: ["lane:nuc"], label_prefixes: ["nuc"]}
    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(%{"instance" => %{"ignore" => %{"tickets" => ["x"]}}})
  end

  test "a ticket is foreign by id, by exact label, or by state-label prefix" do
    rules = %Ignore{tickets: [4121], labels: ["lane:nuc"], label_prefixes: ["nuc"]}

    assert Instance.foreign?(4121, [], rules)
    assert Instance.foreign?("aiur-team/aiur#4121", nil, rules)
    assert Instance.foreign?(7, ["Lane:NUC"], rules)
    assert Instance.foreign?(7, [%{"name" => "nuc:in-progress"}], rules)
    refute Instance.foreign?(7, ["agent:in-progress", "nucleus"], rules)
    refute Instance.foreign?(7, [], %Ignore{})
  end

  test "label rules resolve through the open-ticket label snapshot when callers only have an identifier" do
    previous = Application.get_env(:aiur, :instance_ticket_labels_fun)

    Application.put_env(:aiur, :instance_ticket_labels_fun, fn
      4122 -> ["nuc:in-progress"]
      _ -> []
    end)

    on_exit(fn -> if previous, do: Application.put_env(:aiur, :instance_ticket_labels_fun, previous), else: Application.delete_env(:aiur, :instance_ticket_labels_fun) end)

    assert Instance.foreign?("owner/repo#4122", nil, %Ignore{label_prefixes: ["nuc"]})
  end

  test "prefix rules treat a closed ticket with unavailable labels as foreign" do
    previous = Application.get_env(:aiur, :instance_ticket_labels_fun)
    Application.put_env(:aiur, :instance_ticket_labels_fun, fn _number -> nil end)
    on_exit(fn -> restore_label_lookup(previous) end)

    assert Instance.foreign?("owner/repo#4123", nil, %Ignore{label_prefixes: ["nuc"]})
  end

  test "prefix rules fail closed when the open-ticket label snapshot is missing" do
    previous = Application.fetch_env(:aiur, :instance_ticket_labels_fun)
    Application.delete_env(:aiur, :instance_ticket_labels_fun)

    on_exit(fn ->
      case previous do
        {:ok, lookup} -> Application.put_env(:aiur, :instance_ticket_labels_fun, lookup)
        :error -> Application.delete_env(:aiur, :instance_ticket_labels_fun)
      end
    end)

    assert Instance.foreign?("owner/repo#4124", nil, %Ignore{label_prefixes: ["nuc"]})
  end

  test "unreadable config suppresses ticket-scoped ownership work" do
    previous = Application.fetch_env(:aiur, :backend_catalog)
    Application.put_env(:aiur, :backend_catalog, nil)

    on_exit(fn ->
      case previous do
        {:ok, catalog} -> Application.put_env(:aiur, :backend_catalog, catalog)
        :error -> Application.delete_env(:aiur, :backend_catalog)
      end
    end)

    refute match?({:ok, _rules}, Instance.rules_result())
    assert Instance.foreign?(4125)
    assert Instance.foreign_pr?([4125])

    snapshot = %{tickets: [%{number: 4125}], pull_requests: [%{number: 9}], merge_groups: [%{head_branch: "gh-readonly-queue/main/pr-9-abc"}]}
    filtered = SweepFilter.own(snapshot)
    assert filtered.tickets == []
    assert filtered.pull_requests == []
    assert filtered.merge_groups == []
  end

  test "the Executor sweep drops another instance's unreviewed PR and merge group" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path())
    ignore!("    tickets: [4430]\n")
    now = ~U[2026-10-15 18:20:00Z]
    pr = fn number, ticket -> %{number: number, issue_number: ticket, state: "open", draft: false, head_sha: "h", reviewed_head_sha: nil, ready_at: ~U[2026-10-14 19:08:00Z]} end
    group = fn number -> %{name: "run #{number}", head_branch: "gh-readonly-queue/main/pr-#{number}-abc", state: "queued", started_at: ~U[2026-10-15 17:00:00Z]} end

    snapshot = %{
      tickets: [%{number: 4429, labels: ["agent:human-review"]}, %{number: 4430, labels: ["agent:human-review"]}],
      decisions: [%{ticket: 4430, blocking: true}, %{ticket: 4429, blocking: true}],
      pull_requests: [pr.(4447, 4429), pr.(4448, 4430)],
      merge_groups: [group.(4447), group.(4448)]
    }

    findings = Aiur.ExecutorSweep.findings(snapshot: snapshot, now: now)
    assert Enum.map(SweepFilter.own(snapshot).decisions, & &1.ticket) == [4429]
    assert for(%{kind: "unreviewed_pr", ticket_state: "human-review", pull_request: n} <- findings, do: n) == [4447]
    assert for(%{kind: "stale_merge_group", merge_group: name} <- findings, do: name) == ["run 4447"]
  end

  test "aiur status names the active rules and the ignored count" do
    assert Instance.status_line(%{tickets: [4121], labels: ["lane:nuc"], label_prefixes: [], ignored_since_boot: 3}) ==
             "INSTANCE IGNORE tickets=[4121] labels=[lane:nuc] label_prefixes=[] ignored_since_boot=3"

    write_workflow_file!(Aiur.Workflow.workflow_file_path())
    ignore!("    tickets: [4121]\n")
    Instance.ignored(4121, :test)
    assert Instance.status_line() =~ "tickets=[4121] labels=[] label_prefixes=[] ignored_since_boot=#{Instance.ignored_count()}"
    assert Instance.ignored_count() > 0
  end

  defp ignore!(rules) do
    path = Aiur.Workflow.workflow_file_path()
    write_workflow_file_atomic!(path, File.read!(path) <> "\ninstance:\n  ignore:\n" <> rules)
    :ok = Aiur.WorkflowStore.force_reload()
  end

  defp restore_label_lookup({:ok, lookup}), do: Application.put_env(:aiur, :instance_ticket_labels_fun, lookup)
  defp restore_label_lookup(lookup) when is_function(lookup, 1), do: Application.put_env(:aiur, :instance_ticket_labels_fun, lookup)
  defp restore_label_lookup(nil), do: Application.delete_env(:aiur, :instance_ticket_labels_fun)

  test "rules hot-reload from the live config and ignored events are counted" do
    path = Aiur.Workflow.workflow_file_path()
    write_workflow_file!(path)
    refute Instance.foreign?(4121, [])

    write_workflow_file_atomic!(path, File.read!(path) <> "\ninstance:\n  ignore:\n    tickets: [4121]\n")
    :ok = Aiur.WorkflowStore.force_reload()

    assert Instance.foreign?(4121, [])
    assert Instance.foreign_pr?([3, "#4121"])
    refute Instance.foreign_pr?([3])

    before = Instance.ignored_count()
    assert Instance.skip?(4121, [], :test)
    refute Instance.skip?(3, [], :test)
    assert Instance.ignored_count() == before + 1
    assert %{tickets: [4121], ignored_since_boot: count} = Instance.status()
    assert count == before + 1
  end
end
