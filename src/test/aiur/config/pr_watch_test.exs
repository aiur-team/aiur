defmodule Aiur.Config.PrWatchTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema

  describe "pr_watch config block" do
    test "defaults to disabled with the watch label and /aiur command when absent" do
      {:ok, settings} = Schema.parse(%{})

      assert settings.pr_watch.enabled == false
      assert settings.pr_watch.watch_label == "watch"
      assert settings.pr_watch.command_prefix == "/aiur"
    end

    test "parses the enabled flag and label/command overrides" do
      {:ok, settings} =
        Schema.parse(%{
          "pr_watch" => %{
            "enabled" => true,
            "watch_label" => "review",
            "command_prefix" => "/bot"
          }
        })

      assert settings.pr_watch.enabled == true
      assert settings.pr_watch.watch_label == "review"
      assert settings.pr_watch.command_prefix == "/bot"
    end

    test "rejects a blank watch_label" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"pr_watch" => %{"watch_label" => ""}})

      assert message =~ "watch_label"
    end

    test "rejects a blank command_prefix" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"pr_watch" => %{"command_prefix" => ""}})

      assert message =~ "command_prefix"
    end
  end
end
