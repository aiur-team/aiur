defmodule Aiur.TestBootstrapConfigTest do
  use ExUnit.Case, async: false

  @fixture_path Path.expand("fixtures/test.aiurconfig", __DIR__)
  @config_path Path.expand("../config/config.exs", __DIR__)
  @test_helper_path Path.expand("test_helper.exs", __DIR__)

  test "test environment boots with the checked-in workflow fixture" do
    config = Config.Reader.read!(@config_path, env: :test)

    assert config[:aiur][:workflow_file_path] == @fixture_path
  end

  test "test config cannot discover repository workflow files" do
    config_source = File.read!(@config_path)

    assert config_source =~
             ~s|config :aiur, :workflow_file_path, Path.expand("../test/fixtures/test.aiurconfig", __DIR__)|

    refute config_source =~ "../../.aiur/config"
    refute config_source =~ "../../.aiurconfig"
  end

  test "application boots with the checked-in workflow fixture active" do
    assert Application.fetch_env!(:aiur, :workflow_file_path) == @fixture_path
  end

  test "test helper cannot override the pre-boot workflow configuration" do
    refute File.read!(@test_helper_path) =~ ":workflow_file_path"
  end
end
