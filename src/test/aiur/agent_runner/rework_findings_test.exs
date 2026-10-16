defmodule Aiur.AgentRunner.ReworkFindingsTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.{ReworkFindings, ToolExecutor}
  alias Aiur.Issue

  @review_body """
  Request changes at 26fc093fa.

  1. src/lib/aiur/agent_runner/rework_handoff.ex:44-45 (with rework_handoff_guard.ex:52): `Keyword.get` passes an explicit `nil`.
  2. The re-review does not receive the worker's answers.
  3) src/lib/aiur/agent_runner/rework_checklist.ex:70: match commits by prefix.
  4. dedup.ex:~118-136: approximate lines still count.

  Also: revert the unrelated reformatting.
  """

  describe "parse/1" do
    test "keeps the reviewer's numbers and skips items without file:line" do
      assert [
               %{id: "1", file: "src/lib/aiur/agent_runner/rework_handoff.ex", line: "44", ask: "src/lib/aiur/agent_runner/rework_handoff.ex:44-45" <> _},
               %{id: "3", file: "src/lib/aiur/agent_runner/rework_checklist.ex", line: "70"},
               %{id: "4", file: "dedup.ex", line: "118"}
             ] = ReworkFindings.parse(@review_body)

      assert ReworkFindings.parse("Please fix the tests.") == []
      assert ReworkFindings.parse(nil) == []
    end
  end

  describe "validate/4" do
    @findings [%{id: "1", file: "lib/a.ex", line: "4", ask: "fix a"}, %{id: "2", file: "lib/b.ex", line: "9", ask: "fix b"}]
    @commit String.duplicate("a", 40)

    test "an unchecked finding is refused by id, file:line and ask" do
      assert {:blocked, [reason]} = ReworkFindings.validate(@findings, [%{"id" => "1", "status" => "fixed", "commit" => "aaaaaaa"}], [@commit], ["lib/a.ex"])
      assert reason == "finding 2 (lib/b.ex:9) is unchecked: fix b"
    end

    test "a fixed finding needs a commit since the review that changed its file" do
      answers = [%{"id" => "1", "status" => "fixed", "commit" => "aaaaaaa"}, %{"id" => "2", "status" => "fixed", "commit" => "bbbbbbb"}]

      assert {:blocked, reasons} = ReworkFindings.validate(@findings, answers, [@commit], ["lib/a.ex"])

      assert reasons == [
               "finding 2 (lib/b.ex:9) is marked fixed by \"bbbbbbb\", which is not a commit since the review",
               "finding 2 (lib/b.ex:9) is marked fixed but lib/b.ex was not changed since the review"
             ]
    end

    test "a reviewer's basename or lib/-relative path matches the repo-relative changed file" do
      findings = [%{id: "1", file: "x.ex", line: "62", ask: "fix x"}, %{id: "2", file: "lib/aiur/y.ex", line: "48", ask: "fix y"}]
      answers = [%{"id" => "1", "status" => "fixed", "commit" => "aaaaaaa"}, %{"id" => "2", "status" => "fixed", "commit" => "aaaaaaa"}]

      assert ReworkFindings.validate(findings, answers, [@commit], ["src/lib/aiur/landing/x.ex", "src/lib/aiur/y.ex"]) == :allow

      assert {:blocked, ["finding 2 (lib/aiur/y.ex:48) is marked fixed but lib/aiur/y.ex was not changed since the review"]} =
               ReworkFindings.validate(findings, answers, [@commit], ["src/lib/aiur/landing/x.ex", "src/lib/aiur/notlib/aiur_y.ex"])
    end

    test "short SHAs match by prefix and extra answers are ignored" do
      answers = [
        %{"id" => "1", "status" => "fixed", "commit" => "aaaaaaa"},
        %{"id" => "2", "status" => "disputed", "evidence" => "b.ex:9 already handles nil"},
        %{"id" => "9", "status" => "fixed", "commit" => "zzz"}
      ]

      assert ReworkFindings.validate(@findings, answers, [@commit], ["lib/a.ex"]) == :allow
      assert {:blocked, _} = ReworkFindings.validate(@findings, put_in(answers, [Access.at(0), "commit"], "aaaa"), [@commit], ["lib/a.ex"])
    end

    test "every finding disputed with evidence goes back without a new commit" do
      answers = [%{"id" => "1", "status" => "disputed", "evidence" => "x"}, %{"id" => "2", "status" => "disputed", "evidence" => "y"}]
      assert ReworkFindings.validate(@findings, answers, [], :unknown) == :allow

      assert {:blocked, ["finding 2 (lib/b.ex:9) is disputed without evidence"]} =
               ReworkFindings.validate(@findings, put_in(answers, [Access.at(1), "evidence"], " "), [], :unknown)
    end

    test "a handback with no commits since the review is refused" do
      assert ReworkFindings.validate([], nil, [], :unknown) == {:blocked, ["no new commits since the review"]}
      assert ReworkFindings.validate([], nil, [@commit], []) == :allow
      assert ReworkFindings.validate([], nil, :unknown, :unknown) == :allow
    end
  end

  describe "branch_changes/3" do
    @describetag :tmp_dir

    test "lists the branch's own commits and files, not a merged base's", %{tmp_dir: repo} do
      git(repo, ["init", "-q", "-b", "main"])
      review = commit(repo, "a.ex")
      # A base commit off the review head, then a merge of it on top of the fix, built with plumbing only.
      File.write!(Path.join(repo, "from_main.ex"), "main\n")
      git(repo, ["add", "from_main.ex"])
      base = commit_tree(repo, ["-p", review])
      git(repo, ["rm", "-q", "--cached", "from_main.ex"])
      fix = commit(repo, "b.ex")
      git(repo, ["add", "from_main.ex"])
      head = commit_tree(repo, ["-p", fix, "-p", base])

      assert ReworkFindings.branch_changes(repo, review, head) == {[fix], ["b.ex"]}
      assert ReworkFindings.branch_changes(repo, review, review) == {[], :unknown}
      assert ReworkFindings.branch_changes(Path.join(repo, "missing"), review, head) == {:unknown, :unknown}
    end
  end

  describe "aiur_set_ticket_state rework handback" do
    @describetag :tmp_dir

    test "refuses unaddressed or untouched findings, then posts the verified checklist", %{tmp_dir: repo} do
      git(repo, ["init", "-q", "-b", "main"])
      review = commit(repo, "lib/a.ex")
      fix = commit(repo, "lib/a.ex")
      body = "1. lib/a.ex:3 rename the helper\n2. lib/b.ex:7 drop the nil key\n"
      test_pid = self()

      executor =
        ToolExecutor.build(%Issue{id: "4654", identifier: "4654", state: "rework"}, repo, nil, %{},
          coordination_runner: fn _key, operation, _opts -> operation.() end,
          ticket_state_writer: fn issue_id, state -> send(test_pid, {:state_write, issue_id, state}) && :ok end,
          open_pr_fetcher: fn "4654" -> {:ok, %{"number" => 4673, "head" => %{"sha" => fix}}} end,
          reviews_fetcher: fn 4673 ->
            {:ok, [%{"state" => "CHANGES_REQUESTED", "body" => body, "commit_id" => review, "submitted_at" => "2026-10-16T09:17:56Z", "id" => 1, "user" => %{"login" => "r"}, authoritative: true}]}
          end,
          pull_request_fetcher: fn 4673 -> {:ok, %{"mergeable_state" => "clean"}} end,
          checklist_commenter: fn issue_id, comment -> send(test_pid, {:comment, issue_id, comment}) end
        )

      hand_back = fn answers -> executor.("aiur_set_ticket_state", %{"state" => "ci-wait", "review_findings" => answers}) end
      error = fn response -> Jason.decode!(response["output"])["error"] end

      unchecked = hand_back.([%{"id" => "1", "status" => "fixed", "commit" => String.slice(fix, 0, 7)}])
      assert error.(unchecked)["reason"] == "rework_findings_unaddressed"
      assert error.(unchecked)["message"] =~ "finding 2 (lib/b.ex:7) is unchecked: lib/b.ex:7 drop the nil key"

      untouched = hand_back.([%{"id" => "1", "status" => "fixed", "commit" => fix}, %{"id" => "2", "status" => "fixed", "commit" => fix}])
      assert error.(untouched)["message"] =~ "finding 2 (lib/b.ex:7) is marked fixed but lib/b.ex was not changed since the review"
      refute_received {:state_write, _, _}

      answers = [%{"id" => "1", "status" => "fixed", "commit" => fix}, %{"id" => "2", "status" => "disputed", "evidence" => "b.ex has no nil key"}]
      assert hand_back.(answers)["success"]
      assert_receive {:state_write, "4654", "ci-wait"}, 100
      assert_receive {:comment, "4654", comment}, 100
      assert comment =~ "- [x] 2. `lib/b.ex:7`"
      assert comment =~ "**disputed**: b.ex has no nil key"
    end

    test "refuses a handback with no commits since the review and a conflicting PR" do
      head = String.duplicate("c", 40)
      test_pid = self()

      executor = fn mergeable_state ->
        ToolExecutor.build(%Issue{id: "4654", identifier: "4654", state: "rework"}, nil, nil, %{},
          coordination_runner: fn _key, operation, _opts -> operation.() end,
          ticket_state_writer: fn _issue_id, _state -> send(test_pid, :unexpected_write) && :ok end,
          open_pr_fetcher: fn "4654" -> {:ok, %{"number" => 4673, "head" => %{"sha" => head}}} end,
          reviews_fetcher: fn 4673 ->
            {:ok, [%{"state" => "CHANGES_REQUESTED", "body" => "Fix CI.", "commit_id" => head, "submitted_at" => "2026-10-16T09:17:56Z", "id" => 1, "user" => %{"login" => "r"}, authoritative: true}]}
          end,
          pull_request_fetcher: fn 4673 -> {:ok, %{"mergeable_state" => mergeable_state}} end
        )
      end

      response = executor.("clean").("aiur_set_ticket_state", %{"state" => "ci-wait"})
      assert Jason.decode!(response["output"])["error"]["message"] =~ "no new commits since the review"

      response = executor.("dirty").("aiur_set_ticket_state", %{"state" => "ci-wait"})
      assert Jason.decode!(response["output"])["error"]["reason"] == "pull_request_conflicting"
      refute_received :unexpected_write
    end
  end

  defp commit(repo, file) do
    path = Path.join(repo, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#{System.unique_integer()}\n")
    git(repo, ["add", file])
    git(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", file])
    git(repo, ["rev-parse", "HEAD"])
  end

  defp commit_tree(repo, parents) do
    tree = git(repo, ["write-tree"])
    git(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit-tree", tree, "-m", "plumbing" | parents])
  end

  defp git(repo, args) do
    {out, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    String.trim(out)
  end
end
