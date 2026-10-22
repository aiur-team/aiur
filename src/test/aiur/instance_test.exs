defmodule Aiur.InstanceTest do
  use Aiur.TestSupport

  alias Aiur.Config.Schema
  alias Aiur.Config.Schema.Instance.Ignore
  alias Aiur.Instance

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
