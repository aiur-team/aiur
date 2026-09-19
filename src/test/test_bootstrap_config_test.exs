defmodule Aiur.TestBootstrapConfigTest do
  use ExUnit.Case, async: false

  alias Aiur.{GitHub.CiReadiness, ModelAvailability, ModelDiscovery, Workflow}

  @fixture_path Path.expand("fixtures/test.yaml", __DIR__)
  @fixture_content File.read!(@fixture_path)
  @config_path Path.expand("../config/config.exs", __DIR__)
  @test_helper_path Path.expand("test_helper.exs", __DIR__)

  setup do
    env = System.get_env()

    on_exit(fn ->
      for name <- Map.keys(System.get_env()) -- Map.keys(env), do: System.delete_env(name)
      System.put_env(env)
    end)
  end

  test "test environment boots with a disposable copy of the workflow fixture" do
    config = Config.Reader.read!(@config_path, env: :test)

    workflow_file_path = config[:aiur][:workflow_file_path]
    on_exit(fn -> File.rm_rf!(config[:aiur][:test_state_root]) end)

    assert is_binary(workflow_file_path)
    assert Path.basename(workflow_file_path) == "test.yaml"
    assert String.starts_with?(workflow_file_path, System.tmp_dir!())
    assert_disposable_fixture(workflow_file_path)
  end

  test "test config cannot discover repository workflow files" do
    config_source = File.read!(@config_path)

    assert config_source =~ ~s|File.read!(Path.expand("../test/fixtures/test.yaml", __DIR__))|
    assert config_source =~ ~s|config :aiur, :workflow_file_path, test_workflow_file_path|

    refute config_source =~ "../../.aiur/config"
    refute config_source =~ "../../.aiurconfig"
  end

  test "application boots with the disposable workflow fixture active" do
    workflow_file_path = Application.fetch_env!(:aiur, :workflow_file_path)

    assert Path.basename(workflow_file_path) == "test.yaml"
    assert String.starts_with?(workflow_file_path, System.tmp_dir!())
    assert_disposable_fixture(workflow_file_path)
  end

  test "test helper cannot override the pre-boot workflow configuration" do
    refute File.read!(@test_helper_path) =~ ":workflow_file_path"
  end

  test "every path derived from the workflow file directory resolves outside the checkout in the test env" do
    workflow_dir = Path.dirname(Workflow.workflow_file_path())
    checkout_fixtures = Path.expand("fixtures", __DIR__)

    refute String.starts_with?(workflow_dir, checkout_fixtures),
           "baseline workflow dir must not resolve inside the checkout"

    derived_paths = [
      ModelAvailability.path(),
      ModelDiscovery.path(),
      CiReadiness.assessment_path()
    ]

    for path <- derived_paths do
      assert String.starts_with?(path, System.tmp_dir!()),
             "derived path #{inspect(path)} must resolve under the system tmp dir"
    end
  end

  defp assert_disposable_fixture(path) do
    refute path == @fixture_path
    assert File.read!(@fixture_path) == @fixture_content
    {:ok, original} = YamlElixir.read_from_string(@fixture_content)
    {:ok, disposable} = YamlElixir.read_from_file(path)
    workspace_root = Path.join(Path.dirname(path), "workspaces")
    assert get_in(disposable, ["workspace", "root"]) == workspace_root
    assert put_in(disposable, ["workspace", "root"], original["workspace"]["root"]) == original
  end
end
