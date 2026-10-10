defmodule Aiur.Config.MergePolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema

  test "absent section supplies every merge policy default" do
    assert {:ok, settings} = Schema.parse(%{})
    policy = settings.merge_policy
    assert policy.ci == "wait"
    assert policy.local_tests == "partial"
    assert policy.full_ci_labels == ["main-fix"]
    assert policy.full_ci_paths == []
    assert policy.premerge_checks == []
    assert policy.attribution_scan == false
    assert policy.main_watch.enabled == false
    assert policy.main_watch.workflows == []
    assert policy.main_watch.on_red == "alert"
    assert policy.main_watch.fixer_label == "main-fix"
    assert policy.main_watch.canary_minutes == 45
    assert policy.main_watch.red_fallback_minutes == 0
  end

  test "parses a complete early merge policy and nested watcher overrides" do
    policy = %{
      ci: "pending_ok",
      local_tests: "all",
      full_ci_labels: ["HOTFIX"],
      full_ci_paths: [".github/workflows/**"],
      premerge_checks: ["python3 scripts/check-components.py"],
      attribution_scan: true,
      main_watch: %{enabled: true, workflows: ["ci"], on_red: "dispatch_fixer", fixer_label: "hotfix", canary_minutes: 0, red_fallback_minutes: 60}
    }

    assert {:ok, settings} = Schema.parse(%{merge_policy: policy})
    actual = Map.from_struct(settings.merge_policy)
    assert Map.delete(actual, :main_watch) == Map.delete(policy, :main_watch)
    assert Map.from_struct(actual.main_watch) == policy.main_watch
  end

  test "null settings use defaults consistently with other config sections" do
    assert {:ok, defaults} = Schema.parse(%{})
    assert {:ok, settings} = Schema.parse(%{merge_policy: %{ci: nil, local_tests: nil, full_ci_labels: nil, main_watch: nil}})
    assert settings.merge_policy == defaults.merge_policy
    assert settings.merge_policy.ci == "wait"
    assert settings.merge_policy.full_ci_labels == ["main-fix"]

    assert {:ok, nested} = Schema.parse(%{merge_policy: %{main_watch: %{enabled: nil, fixer_label: nil, canary_minutes: nil, red_fallback_minutes: nil}}})
    assert nested.merge_policy == defaults.merge_policy
    assert nested.merge_policy.main_watch.canary_minutes == 45
    assert nested.merge_policy.main_watch.red_fallback_minutes == 0
  end

  test "pending CI requires the main watcher, including when omitted" do
    for watch <- [%{}, %{main_watch: %{enabled: false}}] do
      message = error(Map.put(watch, :ci, "pending_ok"))
      assert message =~ "merge_policy.ci pending_ok requires merge_policy.main_watch.enabled to be true"
    end
  end

  test "pending CI cannot disable local tests" do
    message = error(%{ci: "pending_ok", local_tests: "none", main_watch: %{enabled: true}})
    assert message =~ "merge_policy.local_tests must be all or partial when merge_policy.ci is pending_ok"
  end

  test "dispatching a fixer requires its label in full CI labels" do
    message = error(%{full_ci_labels: [], main_watch: %{on_red: "dispatch_fixer", fixer_label: "hotfix"}})
    assert message =~ "merge_policy.full_ci_labels must include merge_policy.main_watch.fixer_label"
    assert message =~ "merge_policy.main_watch.on_red is dispatch_fixer"
  end

  test "wait permits no local tests and a disabled watcher" do
    assert {:ok, settings} = Schema.parse(%{merge_policy: %{ci: "wait", local_tests: "none"}})
    assert settings.merge_policy.local_tests == "none"
    assert settings.merge_policy.main_watch.enabled == false
  end

  test "invalid enums report dotted paths and allowed values" do
    assert error(%{ci: "maybe"}) =~ "merge_policy.ci must be one of: wait, pending_ok"
    assert error(%{local_tests: "some"}) =~ "merge_policy.local_tests must be one of: all, partial, none"
    assert error(%{main_watch: %{on_red: "ignore"}}) =~ "merge_policy.main_watch.on_red must be one of: alert, dispatch_fixer"
  end

  test "every string list rejects blank entries and invalid list types" do
    for field <- [:full_ci_labels, :full_ci_paths, :premerge_checks], invalid <- [[""], [" \t"], [nil], [7], "main-fix"] do
      assert error(%{field => invalid}) =~ "merge_policy.#{field}"
    end

    for invalid <- [[""], [" \t"], [nil], [7], "ci"] do
      assert error(%{main_watch: %{workflows: invalid}}) =~ "merge_policy.main_watch.workflows"
    end
  end

  test "main watcher validates fixer labels and non-negative whole canary minutes" do
    for value <- ["", " \t"] do
      assert error(%{main_watch: %{fixer_label: value}}) =~ "merge_policy.main_watch.fixer_label must be a non-empty string"
    end

    for value <- [-1, 1.5, "2"] do
      assert error(%{main_watch: %{canary_minutes: value}}) =~ "merge_policy.main_watch.canary_minutes"
    end
  end

  test "invalid booleans and section shapes fail config parsing" do
    for policy <- [%{attribution_scan: "maybe"}, %{main_watch: %{enabled: "maybe"}}, %{main_watch: "on"}] do
      assert error(policy) =~ "merge_policy."
    end

    assert error("wait") =~ "merge_policy"
  end

  test "red fallback accepts zero and whole minutes and rejects coercion" do
    for minutes <- [0, 60] do
      assert {:ok, settings} = Schema.parse(%{merge_policy: %{main_watch: %{red_fallback_minutes: minutes}}})
      assert settings.merge_policy.main_watch.red_fallback_minutes == minutes
    end

    for value <- [-1, 1.5, "60", true] do
      assert error(%{main_watch: %{red_fallback_minutes: value}}) =~ "merge_policy.main_watch.red_fallback_minutes must be a non-negative integer"
    end
  end

  defp error(policy) do
    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{merge_policy: policy})
    message
  end
end
