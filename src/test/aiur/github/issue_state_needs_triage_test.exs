defmodule Aiur.GitHub.IssueStateNeedsTriageTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.IssueState
  alias Aiur.GitHub.ResourceStore

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    previous_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_token)

      case previous_cached_token do
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

  test "needs-triage is added before every agent state label is removed" do
    test_pid = self()
    state_labels = ["sym:in-progress", "sym:rework", "other"]

    request_fun = fn req ->
      send(test_pid, {:triage_state_request, req})

      case req.method do
        :get ->
          {:ok, %{status: 200, body: %{"state" => "open", "labels" => Enum.map(state_labels, &%{"name" => &1})}}}

        :post ->
          assert req.body == %{"labels" => ["sym:needs-triage"]}
          {:ok, %{status: 200}}

        :delete ->
          {:ok, %{status: 200}}

        _other ->
          flunk("unexpected request: #{inspect(req)}")
      end
    end

    assert :ok = IssueState.update_issue_state("42", "needs-triage", request_fun: request_fun)

    requests = collect_state_requests([])
    add_index = Enum.find_index(requests, &(&1.method == :post and &1.body == %{"labels" => ["sym:needs-triage"]}))
    remove_indexes = Enum.with_index(requests) |> Enum.filter(fn {req, _index} -> req.method == :delete end) |> Enum.map(&elem(&1, 1))

    removed_labels = Enum.map(remove_indexes, &Enum.at(requests, &1).url) |> Enum.map(&URI.decode/1)

    assert is_integer(add_index)
    assert length(remove_indexes) == 2
    assert Enum.all?(remove_indexes, &(&1 > add_index))
    assert Enum.any?(removed_labels, &String.ends_with?(&1, "sym:in-progress"))
    assert Enum.any?(removed_labels, &String.ends_with?(&1, "sym:rework"))
  end

  defp collect_state_requests(requests) do
    receive do
      {:triage_state_request, req} -> collect_state_requests([req | requests])
    after
      0 -> Enum.reverse(requests)
    end
  end
end
