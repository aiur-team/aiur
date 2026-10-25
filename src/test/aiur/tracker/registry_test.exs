defmodule Aiur.Tracker.RegistryTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Tracker.Registry

  defmodule CustomConfig do
    def validate_settings(_settings), do: {:error, :custom_tracker_settings}
  end

  defmodule CustomTracker do
    def config_module, do: CustomConfig
    def code_host, do: __MODULE__
  end

  defmodule BareTracker do
  end

  test "optional callbacks can be absent" do
    Application.put_env(:aiur, :tracker_adapters, %{"bare" => BareTracker})
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "bare")
    assert Registry.config_module("bare") == nil
    assert Aiur.CodeHost.adapter() == Aiur.Tracker.NullCodeHost
    assert Config.validate!() == :ok
  end

  setup do
    adapters = Application.fetch_env!(:aiur, :tracker_adapters)
    fallback = Application.fetch_env!(:aiur, :tracker_fallback_kind)
    token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "registry-test-token")

    on_exit(fn ->
      Application.put_env(:aiur, :tracker_adapters, adapters)
      Application.put_env(:aiur, :tracker_fallback_kind, fallback)
      if token, do: System.put_env("GITHUB_TOKEN", token), else: System.delete_env("GITHUB_TOKEN")
    end)

    :ok
  end

  test "shipped adapters and legacy fallback are registered" do
    assert Registry.kinds() == ["github", "linear", "memory"]

    for {kind, adapter, config} <- [
          {"github", Aiur.GitHub.Tracker, Aiur.GitHub.Config},
          {"linear", Aiur.Linear.Tracker, Aiur.Linear.Config},
          {"memory", Aiur.Memory.Tracker, Aiur.Memory.Config}
        ] do
      assert Registry.adapter_for(kind) == adapter
      assert Registry.config_module(kind) == config
    end

    assert Registry.adapter_for("123") == Aiur.Linear.Tracker
    assert Registry.adapter_for(nil) == Aiur.Linear.Tracker
    assert Registry.config_module("123") == nil
    Application.put_env(:aiur, :tracker_fallback_kind, "memory")
    assert Registry.adapter_for("123") == Aiur.Memory.Tracker
  end

  test "registered adapter drives public tracker, code host and settings validation" do
    Application.put_env(:aiur, :tracker_adapters, %{"custom" => CustomTracker})
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "custom")
    assert Registry.kinds() == ["custom"]
    assert Aiur.Tracker.adapter() == CustomTracker
    assert Aiur.CodeHost.adapter() == CustomTracker
    assert Config.validate!() == {:error, :custom_tracker_settings}

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    assert Config.validate!() == {:error, {:unsupported_tracker_kind, "memory"}}
  end

  test "missing adapter registry fails loudly" do
    Application.delete_env(:aiur, :tracker_adapters)
    assert_raise ArgumentError, fn -> Registry.kinds() end
  end

  test "legacy regression: validation precedence survives tracker registration" do
    for {overrides, expected} <- [
          {[tracker_kind: nil], {:error, :missing_tracker_kind}},
          {[tracker_kind: "123"], {:error, {:unsupported_tracker_kind, "123"}}},
          {[tracker_kind: "linear", agent_kind: "bad", tracker_api_token: nil], {:error, {:unsupported_agent_kind, "bad"}}},
          {[tracker_api_token: nil], {:error, :missing_linear_api_token}},
          {[tracker_project_slug: nil], {:error, :missing_linear_project_slug}}
        ] do
      write_workflow_file!(Workflow.workflow_file_path(), overrides)
      assert Config.validate!() == expected
    end

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "example/repo", agent_kind: "claude", command: "   ")
    assert Config.validate!() == :ok
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", agent_kind: "claude", command: "   ")
    assert {:error, "Claude command missing — set claude.command in .aiur/config"} = Config.validate!()
  end
end
