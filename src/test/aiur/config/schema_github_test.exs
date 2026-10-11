defmodule Aiur.Config.SchemaGithubTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema

  describe "GitHub planning graph bounds" do
    test "the checked-in GitHub workflow fixture satisfies the planning bounds" do
      fixture = Path.expand("../../fixtures/test.yaml", __DIR__)

      assert {:ok, config} = YamlElixir.read_from_file(fixture)
      assert {:ok, settings} = Schema.parse(config)

      assert settings.tracker.github.planning_root_limit == 100
      assert settings.tracker.github.planning_page_budget == 4
      assert settings.tracker.github.planning_call_budget == 4
    end

    test "defaults to finite bounds that permit one hundred roots" do
      assert {:ok, settings} = Schema.parse(%{})

      assert settings.tracker.github.planning_root_limit == 100
      assert settings.tracker.github.planning_page_budget == 4
      assert settings.tracker.github.planning_call_budget == 4
    end

    test "accepts lower positive planning graph bounds" do
      assert {:ok, settings} =
               Schema.parse(%{
                 "tracker" => %{
                   "github" => %{
                     "planning_root_limit" => 25,
                     "planning_page_budget" => 2,
                     "planning_call_budget" => 3
                   }
                 }
               })

      assert settings.tracker.github.planning_root_limit == 25
      assert settings.tracker.github.planning_page_budget == 2
      assert settings.tracker.github.planning_call_budget == 3
    end

    test "rejects zero, negative, non-integer, and over-hard-limit planning graph bounds" do
      invalid = [
        {"planning_root_limit", [0, -1, 101, "infinite"]},
        {"planning_page_budget", [0, -1, 5, "infinite"]},
        {"planning_call_budget", [0, -1, 5, "infinite"]}
      ]

      for {field, values} <- invalid, value <- values do
        assert {:error, {:invalid_workflow_config, message}} =
                 Schema.parse(%{"tracker" => %{"github" => %{field => value}}})

        assert message =~ "tracker.github.#{field}"
      end
    end
  end

  describe "GitHub shared request budget" do
    test "defaults to a conservative shared ceiling and accepts explicit tuning" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.tracker.github.max_inflight == 4
      assert defaults.tracker.github.max_inflight_per_endpoint == 2
      assert defaults.tracker.github.requests_per_minute == 120
      assert defaults.tracker.github.stagger_ms == 75

      assert {:ok, settings} =
               Schema.parse(%{
                 "tracker" => %{
                   "github" => %{
                     "max_inflight" => 8,
                     "max_inflight_per_endpoint" => 3,
                     "requests_per_minute" => 240,
                     "stagger_ms" => 125
                   }
                 }
               })

      assert settings.tracker.github.max_inflight == 8
      assert settings.tracker.github.max_inflight_per_endpoint == 3
      assert settings.tracker.github.requests_per_minute == 240
      assert settings.tracker.github.stagger_ms == 125
    end

    test "defaults per-actor hourly ceilings and accepts explicit tuning" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.tracker.github.daemon_core_limit_per_hour == 3000
      assert defaults.tracker.github.daemon_graphql_limit_per_hour == 4500
      assert defaults.tracker.github.daemon_search_limit_per_hour == 600
      assert defaults.tracker.github.agent_core_limit_per_hour == 250
      assert defaults.tracker.github.agent_graphql_limit_per_hour == 600
      assert defaults.tracker.github.agent_search_limit_per_hour == 600

      assert {:ok, settings} =
               Schema.parse(%{
                 "tracker" => %{
                   "github" => %{
                     "daemon_core_limit_per_hour" => 2000,
                     "daemon_graphql_limit_per_hour" => 1500,
                     "daemon_search_limit_per_hour" => 900,
                     "agent_core_limit_per_hour" => 600,
                     "agent_graphql_limit_per_hour" => 300,
                     "agent_search_limit_per_hour" => 450
                   }
                 }
               })

      assert settings.tracker.github.daemon_core_limit_per_hour == 2000
      assert settings.tracker.github.daemon_graphql_limit_per_hour == 1500
      assert settings.tracker.github.daemon_search_limit_per_hour == 900
      assert settings.tracker.github.agent_core_limit_per_hour == 600
      assert settings.tracker.github.agent_graphql_limit_per_hour == 300
      assert settings.tracker.github.agent_search_limit_per_hour == 450
    end

    test "rejects a negative per-actor hourly ceiling" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{
                 "tracker" => %{"github" => %{"agent_core_limit_per_hour" => -1}}
               })

      assert message =~ "tracker.github.agent_core_limit_per_hour"
    end

    test "rejects an endpoint ceiling above the shared ceiling" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"tracker" => %{"github" => %{"max_inflight" => 2, "max_inflight_per_endpoint" => 3}}})

      assert message =~ "tracker.github.max_inflight_per_endpoint"
      assert message =~ "must not exceed max_inflight"
    end
  end

  describe "GitHub dispatch allowlist" do
    test "accepts explicit GitHub logins and defaults to an empty explicit list" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.tracker.github.allowed_users == []

      assert {:ok, settings} =
               Schema.parse(%{
                 "tracker" => %{
                   "github" => %{"allowed_users" => ["its-everdred", "its-applekid"]}
                 }
               })

      assert settings.tracker.github.allowed_users == ["its-everdred", "its-applekid"]
    end

    test "rejects blank dispatch allowlist entries" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"tracker" => %{"github" => %{"allowed_users" => [""]}}})

      assert message =~ "tracker.github.allowed_users"
    end
  end

  describe "GitHub human merger allowlist" do
    test "accepts explicit human GitHub logins and defaults to deny all" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.tracker.github.human_mergers == []

      assert {:ok, settings} =
               Schema.parse(%{
                 "tracker" => %{
                   "github" => %{"human_mergers" => ["its-everdred"]}
                 }
               })

      assert settings.tracker.github.human_mergers == ["its-everdred"]
    end

    test "rejects blank human merger allowlist entries" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"tracker" => %{"github" => %{"human_mergers" => [""]}}})

      assert message =~ "tracker.github.human_mergers"
    end
  end

  describe "GitHub identity_mode" do
    test "defaults to separate_account so an existing install is unchanged" do
      assert {:ok, defaults} = Schema.parse(%{})
      assert defaults.tracker.github.identity_mode == "separate_account"
    end

    test "accepts single_account" do
      assert {:ok, settings} =
               Schema.parse(%{"tracker" => %{"github" => %{"identity_mode" => "single_account"}}})

      assert settings.tracker.github.identity_mode == "single_account"
    end

    test "rejects any other spelling rather than silently picking a mode" do
      # Which mode is in effect decides which comments wake an agent, so a typo
      # must fail loudly at config load, not resolve to a guess.
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"tracker" => %{"github" => %{"identity_mode" => "single"}}})

      assert message =~ "tracker.github.identity_mode"
    end
  end
end
