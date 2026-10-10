defmodule Aiur.Capabilities.MergePolicyProviderTest do
  use Aiur.TestSupport
  import ExUnit.CaptureIO

  alias Aiur.Capabilities.{Collector, MergePolicyProvider}

  test "the registered merge policy provider survives the v1 wire projection and human output" do
    report = Aiur.Capabilities.report(table: :missing_merge_policy_test_table)
    assert report.capabilities["merge_policy"] == %{state: :available, mode: "ci=wait local_tests=partial"}
    output = capture_io(fn -> Aiur.CapabilitiesCLI.run(json: true, report_fun: fn -> report end) end)
    wire = Jason.decode!(output)
    assert wire["contract_version"] == 1
    assert wire["capabilities"]["merge_policy"] == %{"state" => "available", "mode" => "ci=wait local_tests=partial"}
    assert Aiur.CapabilitiesCLI.render(report) =~ String.pad_trailing("merge_policy", 25) <> "available  ci=wait local_tests=partial"
  end

  test "the provider reads the configured pending CI policy through the accessor" do
    path = Aiur.Workflow.workflow_file_path()

    write_workflow_file_atomic!(
      path,
      File.read!(path) <>
        """

        merge_policy:
          ci: pending_ok
          main_watch:
            enabled: true
        """
    )

    :ok = Aiur.WorkflowStore.force_reload()
    assert MergePolicyProvider.capability_ids() == ["merge_policy"]
    assert MergePolicyProvider.capabilities(%{}) == %{"merge_policy" => %{state: :available, mode: "ci=pending_ok local_tests=partial"}}
  end

  test "merge policy remains a known capability when no provider is installed" do
    {report, _warnings} = Collector.collect(providers: [])
    assert report.capabilities["merge_policy"] == %{state: :unavailable, reason: :not_installed}
  end
end
