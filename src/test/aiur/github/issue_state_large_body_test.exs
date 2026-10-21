defmodule Aiur.GitHub.IssueStateLargeBodyTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.IssueState
  alias Aiur.GitHub.ResourceStore

  setup do
    previous = System.get_env("GITHUB_TOKEN")
    cached = :persistent_term.get({Aiur.GitHub.Access.Token, :resolved_token}, :unset)
    :persistent_term.erase({Aiur.GitHub.Access.Token, :resolved_token})
    System.put_env("GITHUB_TOKEN", "test-gh-token")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: "sym")
    ResourceStore.reset()

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous)
      if cached == :unset, do: :persistent_term.erase({Aiur.GitHub.Access.Token, :resolved_token}), else: :persistent_term.put({Aiur.GitHub.Access.Token, :resolved_token}, cached)
      ResourceStore.reset()
    end)

    :ok
  end

  test "state transition replaces old labels when the valid issue response exceeds 64 KiB" do
    parent = self()
    body = %{"state" => "open", "labels" => [%{"name" => "sym:ci-wait"}, %{"name" => "sym:rework"}], "body" => String.duplicate("specification ", 5_000)}
    assert byte_size(Jason.encode!(body)) > 65_536

    request_fun = fn request ->
      send(parent, {:request, request})

      case request.method do
        :get -> {:ok, %{status: 200, body: body}}
        :post -> {:ok, %{status: 200}}
        :delete -> {:ok, %{status: 200}}
        other -> flunk("unexpected request: #{inspect(other)}")
      end
    end

    assert :ok = IssueState.update_issue_state("42", "in-progress", request_fun: request_fun)
    assert_received {:request, %{method: :get, max_response_bytes: 524_288}}
    assert_received {:request, %{method: :post, body: %{"labels" => ["sym:in-progress"]}}}
    assert_received {:request, %{method: :delete, url: first}}
    assert first =~ "sym%3Aci-wait" or first =~ "sym:ci-wait"
    assert_received {:request, %{method: :delete, url: second}}
    assert second =~ "sym%3Arework" or second =~ "sym:rework"
  end

  test "state transition accepts the maximum character count in multibyte UTF-8" do
    parent = self()

    body = %{
      "state" => "open",
      "labels" => [%{"name" => "sym:ci-wait"}],
      "body" => String.duplicate("é", 65_536)
    }

    assert String.length(body["body"]) == 65_536
    assert byte_size(Jason.encode!(body)) > 131_072

    request_fun = fn request ->
      send(parent, {:request, request})

      case request.method do
        :get -> {:ok, %{status: 200, body: body}}
        :post -> {:ok, %{status: 200}}
        :delete -> {:ok, %{status: 200}}
        other -> flunk("unexpected request: #{inspect(other)}")
      end
    end

    assert :ok = IssueState.update_issue_state("43", "in-progress", request_fun: request_fun)
    assert_received {:request, %{method: :get, max_response_bytes: 524_288}}
    assert_received {:request, %{method: :post, body: %{"labels" => ["sym:in-progress"]}}}
    assert_received {:request, %{method: :delete, url: old_label_url}}
    assert old_label_url =~ "sym%3Aci-wait" or old_label_url =~ "sym:ci-wait"
  end
end
