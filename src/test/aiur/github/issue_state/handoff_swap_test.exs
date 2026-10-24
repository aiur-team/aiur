defmodule Aiur.GitHub.IssueState.HandoffSwapTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.IssueState
  alias Aiur.GitHub.ResourceStore

  @token_cache_key {Aiur.GitHub.Access.Token, :resolved_token}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    ResourceStore.reset()
    on_exit(&ResourceStore.reset/0)
    :ok
  end

  describe "update_issue_state/3 across a handoff" do
    # #5796: a ticket waiting on CI that is handed to human review, and later
    # routed to rework, must hold exactly one state label after every write.
    # Leaving `ci-wait` behind makes dispatch authorization deny the rework
    # ticket as contradictory. The fake keeps GitHub's real label set so each
    # step reads what the previous step left.
    test "ci-wait -> human-review -> rework keeps exactly one state label at each step" do
      labels = :ets.new(:handoff_labels, [:set, :public])
      :ets.insert(labels, {:value, ["sym:ci-wait", "sym:watch"]})
      request_fun = stateful_labels_request_fun(labels)

      assert :ok = IssueState.update_issue_state("42", "human-review", request_fun: request_fun)
      assert :ets.lookup_element(labels, :value, 2) |> Enum.sort() == ["sym:human-review", "sym:watch"]

      assert :ok = IssueState.update_issue_state("42", "rework", expected_state: "human-review", request_fun: request_fun)
      assert :ets.lookup_element(labels, :value, 2) |> Enum.sort() == ["sym:rework", "sym:watch"]
    end
  end

  defp stateful_labels_request_fun(labels), do: &stateful_labels_response(&1, labels)

  # The human-review gate searches open pull requests; none is open here.
  defp stateful_labels_response(%{method: :get, url: url}, labels) do
    if url =~ "/pulls", do: {:ok, %{status: 200, body: []}}, else: {:ok, %{status: 200, body: stateful_issue(labels)}}
  end

  defp stateful_labels_response(%{method: :post, body: %{"labels" => added}}, labels) do
    :ets.insert(labels, {:value, Enum.uniq(:ets.lookup_element(labels, :value, 2) ++ added)})
    {:ok, %{status: 200, body: stateful_issue(labels)["labels"]}}
  end

  defp stateful_labels_response(%{method: :delete, url: url}, labels) do
    name = url |> String.split("/labels/") |> List.last() |> URI.decode()
    :ets.insert(labels, {:value, :ets.lookup_element(labels, :value, 2) -- [name]})
    {:ok, %{status: 200, body: stateful_issue(labels)["labels"]}}
  end

  defp stateful_issue(labels),
    do: %{"state" => "open", "labels" => Enum.map(:ets.lookup_element(labels, :value, 2), &%{"name" => &1})}
end
