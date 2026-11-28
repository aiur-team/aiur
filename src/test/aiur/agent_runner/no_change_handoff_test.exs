defmodule Aiur.AgentRunner.NoChangeHandoffTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.NoChangeHandoff
  alias Aiur.Issue

  @commit String.duplicate("b", 40)

  test "verified fix on base is documented and closes an ordinary ticket" do
    test_pid = self()

    opts = [
      base_branch: "main",
      no_change_verifier: fn workspace, base, commit ->
        send(test_pid, {:verified, workspace, base, commit})
        :ok
      end,
      no_change_comment_writer: fn _, _ -> :ok end,
      no_change_state_writer: fn _, state ->
        send(test_pid, {:state, state})
        :ok
      end
    ]

    issue = issue([])

    assert {:ok, %{state: "done", evidence_recorded: true, no_op_limit_exempt: true}} =
             NoChangeHandoff.finish(issue, evidence(), "/workspace", opts)

    assert_received {:verified, "/workspace", "main", @commit}
    assert_received {:state, "done"}
  end

  test "creator-facing ticket goes to Executor review after evidence verification" do
    # Ticket writes are supplied through the module's boundary seam below.
    test_pid = self()

    opts = [
      base_branch: "main",
      no_change_verifier: fn _, _, _ -> :ok end,
      no_change_comment_writer: fn id, body ->
        send(test_pid, {:comment, id, body})
        :ok
      end,
      no_change_state_writer: fn id, state ->
        send(test_pid, {:state, id, state})
        :ok
      end
    ]

    assert {:ok, %{state: "human-review"}} = NoChangeHandoff.finish(issue(["creator-facing"]), evidence(), "/workspace", opts)
    assert_received {:comment, "8205", body}
    assert body =~ @commit
    assert_received {:state, "8205", "human-review"}
  end

  test "refuses a commit not verified on current base and writes nothing" do
    opts = [
      base_branch: "main",
      no_change_verifier: fn _, _, _ -> {:error, :commit_not_on_current_base} end,
      no_change_comment_writer: fn _, _ -> flunk("must not comment") end,
      no_change_state_writer: fn _, _ -> flunk("must not change state") end
    ]

    opts =
      Keyword.merge(opts,
        no_change_comment_writer: fn _, _ -> flunk("must not comment") end,
        no_change_state_writer: fn _, _ -> flunk("must not change state") end
      )

    assert {:error, :commit_not_on_current_base} = NoChangeHandoff.finish(issue([]), evidence(), "/workspace", opts)
  end

  defp issue(labels), do: %Issue{id: 8205, identifier: "8205", labels: labels}
  defp evidence, do: %{"commit" => @commit, "command" => "mix test test/fix_test.exs", "output" => "1 test, 0 failures"}
end
