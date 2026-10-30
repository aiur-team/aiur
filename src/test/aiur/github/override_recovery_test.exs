defmodule Aiur.GitHub.OverrideRecoveryTest do
  use Aiur.TestSupport
  alias Aiur.GitHub.OverrideRecovery

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "deleted branch is distinguished from an unavailable branch read" do
    pr = %{"state" => "open", "merged" => false, "head" => %{"repo" => %{"url" => "https://api.github.com/repos/owner/repo"}, "ref" => "work/6911", "sha" => "before"}}

    for {status, expected} <- [{404, :missing}, {503, :error}] do
      request = fn req ->
        assert req.caller == "command_override_recovery"

        case req.url do
          "https://api.github.com/repos/owner/repo/pulls/77" -> {:ok, %{status: 200, body: pr}}
          "https://api.github.com/repos/owner/repo/git/ref/heads/work%2F6911" -> {:ok, %{status: status, body: %{}}}
        end
      end

      result = OverrideRecovery.pull_request(77, token: "fixture", request_fun: request)

      if expected == :missing do
        assert {:ok, %{number: 77, merged?: false, state: :open, branch_exists?: false, head_ref: "work/6911"}} = result
      else
        assert {:error, {:github, :http, %{status: 503}}} = result
      end
    end
  end

  test "retirement verifies the PR is closed and unmerged before success" do
    parent = self()

    comment = fn "77", "superseded by #9000", opts ->
      assert opts[:caller] == "command_override_supersede"
      send(parent, :commented)
      :ok
    end

    request = fn req ->
      assert_received :commented

      case req.method do
        :patch ->
          assert req.body == %{"state" => "closed"}
          send(parent, :patched)
          send(parent, :commented)
          {:ok, %{status: 200, body: %{"state" => "closed"}}}

        :get ->
          assert_received :patched
          {:ok, %{status: 200, body: %{"state" => "closed", "merged" => false}}}
      end
    end

    assert :ok = OverrideRecovery.close(77, "9000", token: "fixture", request_fun: request, comment: comment, comments: fn _, _ -> {:ok, []} end)
    refute_received :patched

    assert {:error, :superseded_pr_not_closed} =
             OverrideRecovery.close(77, "9000",
               token: "fixture",
               comment: comment,
               comments: fn _, _ -> {:ok, []} end,
               request_fun: fn _ -> {:ok, %{status: 200, body: %{"state" => "open", "merged" => false}}} end
             )
  end

  test "a close retry reuses its existing superseded comment" do
    request = fn req ->
      assert req.method in [:patch, :get]
      {:ok, %{status: 200, body: %{"state" => "closed", "merged" => false}}}
    end

    opts = [token: "fixture", request_fun: request, comments: fn "77", _ -> {:ok, [%{body: "superseded by #9000"}]} end, comment: fn _, _, _ -> flunk("close retry must not post another comment") end]
    assert :ok = OverrideRecovery.close(77, "9000", opts)
    assert :ok = OverrideRecovery.close(77, "9000", opts)
  end
end
