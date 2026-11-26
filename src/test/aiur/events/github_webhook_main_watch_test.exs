defmodule Aiur.Events.GithubWebhookMainWatchTest do
  use ExUnit.Case, async: true
  alias Aiur.Events.GithubWebhook.Normalizer
  @opts [repo: "owner/repo", main_watch_enabled: true, base_branch: "release"]

  test "completed Actions suites on the configured base reconcile main CI" do
    assert {:reconcile, %{kind: :main_ci, head_sha: "abc", source: "check_suite"}} = Normalizer.normalize("check_suite", delivery(), @opts)
  end

  test "check runs use their suite's branch" do
    subject = %{"head_sha" => "abc", "pull_requests" => [], "check_suite" => suite()}
    payload = delivery() |> Map.delete("check_suite") |> Map.put("check_run", subject)
    assert {:reconcile, %{kind: :main_ci, head_sha: "abc", source: "check_run"}} = Normalizer.normalize("check_run", payload, @opts)
  end

  test "future regression guard: disabled, feature branches, third party apps and requested checks remain dropped" do
    assert {:drop, _} = Normalizer.normalize("check_suite", delivery(), Keyword.put(@opts, :main_watch_enabled, false))
    assert {:drop, _} = Normalizer.normalize("check_suite", delivery(), Keyword.put(@opts, :base_branch, "main"))
    assert {:drop, _} = Normalizer.normalize("check_suite", put_in(delivery(), ["check_suite", "app", "slug"], "third-party"), @opts)
    assert {:drop, _} = Normalizer.normalize("check_suite", Map.put(delivery(), "action", "requested"), @opts)
  end

  test "future regression guard: unresolved PR checks do not become main checks" do
    payload = put_in(delivery(), ["check_suite", "pull_requests"], [%{"head" => %{"ref" => "other"}}])
    assert {:drop, _} = Normalizer.normalize("check_suite", payload, @opts)
  end

  defp delivery, do: %{"action" => "completed", "repository" => %{"full_name" => "owner/repo"}, "check_suite" => suite()}
  defp suite, do: %{"head_sha" => "abc", "head_branch" => "release", "pull_requests" => [], "app" => %{"slug" => "github-actions"}}
end
