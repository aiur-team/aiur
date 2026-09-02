defmodule Aiur.Events.PublisherIdentityModeTest do
  @moduledoc """
  The single-account/separate-account split at the self-loop gate (#2501).

  Every case here publishes a comment authored by the configured bot login and
  asserts only on whether the gate let it through, so the assertions cannot pass
  by accident on a build without the marker check: in single-account mode the
  pre-#2501 gate filters on the login alone and returns `:filtered` for the
  human comment these tests require to be delivered.
  """
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, Publisher, Sanitizer}
  alias Aiur.GitHub.AgentMarker
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Workflow

  @bot "aiur-bot"

  defp configure!(mode) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur",
      tracker_bot_account: @bot,
      tracker_identity_mode: mode
    )
  end

  defp comment(body), do: %{issue_number: "42", comment: %{"body" => body}}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      # `identity_mode` lives in the shared workflow file, so leaving it at
      # `single_account` would silently reconfigure every later test in this
      # partition that does not write the file itself. Restore the default.
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_bot_account: @bot
      )

      restore_env("GITHUB_TOKEN", prev_token)

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end

      Publisher.set_tracked_fn(fn _ -> true end)
    end)

    :ok
  end

  describe "single-account mode" do
    setup do
      configure!("single_account")
      :ok
    end

    test "an agent's own comment, carrying the marker, does not wake the agent" do
      :ok = Exchange.subscribe("ticket.42.issue.commented")

      body = "Rework applied, pushed as 1a2b3c4.\n\n" <> AgentMarker.marker()

      assert :filtered =
               Publisher.publish("ticket.42.issue.commented", comment(body),
                 issue_number: "42",
                 actor: @bot
               )

      refute_receive {:event, _}, 100
    end

    test "a human comment from the same login is delivered" do
      :ok = Exchange.subscribe("ticket.42.issue.commented")

      assert {:ok, _id, count} =
               Publisher.publish(
                 "ticket.42.issue.commented",
                 comment("Please use the batched query instead."),
                 issue_number: "42",
                 actor: @bot
               )

      assert count >= 1
      assert_receive {:event, %{topic: "ticket.42.issue.commented", comment: %{"body" => delivered}}}, 500
      assert delivered == "Please use the batched query instead."
    end

    test "an unmarked comment predating the marker reads as human, not as ours" do
      # The absence of a marker is never evidence that Aiur wrote a comment
      # (#2478, #2498). An old comment carries no marker and must still reach
      # the agent.
      :ok = Exchange.subscribe("ticket.42.issue.commented")

      assert {:ok, _id, _count} =
               Publisher.publish(
                 "ticket.42.issue.commented",
                 comment("Comment posted before identity_mode existed."),
                 issue_number: "42",
                 actor: @bot
               )

      assert_receive {:event, _}, 500
    end

    test "a body that only resembles the marker is still treated as human" do
      :ok = Exchange.subscribe("ticket.42.issue.commented")

      assert {:ok, _id, _count} =
               Publisher.publish(
                 "ticket.42.issue.commented",
                 comment("I saw an `<!-- aiur:agent` fragment in the diff — is that intended?"),
                 issue_number: "42",
                 actor: @bot
               )

      assert_receive {:event, _}, 500
    end

    test "a CHANGES_REQUESTED review with a null body reads as human, not as ours" do
      # Reachable, not hypothetical. `GithubCommentsPoller.publish_pr_review_submission/5`
      # puts the raw REST review object under `:comment`, and `actionable_review?/1`
      # passes CHANGES_REQUESTED without inspecting the body — which GitHub returns
      # as null when the reviewer left only inline comments. Since #2473 this is the
      # load-bearing rework signal when there are no threads, so treating it as ours
      # swallows an operator's request for changes outright.
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")

      review = %{"state" => "CHANGES_REQUESTED", "body" => nil, "user" => %{"login" => @bot}}

      assert {:ok, _id, _count} =
               Publisher.publish(
                 "ticket.42.pr.review_comment",
                 %{issue_number: "42", comment: review},
                 issue_number: "42",
                 actor: @bot
               )

      assert_receive {:event, _}, 500
    end

    test "a comment key whose body is missing entirely reads as human" do
      :ok = Exchange.subscribe("ticket.42.issue.commented")

      assert {:ok, _id, _count} =
               Publisher.publish(
                 "ticket.42.issue.commented",
                 %{issue_number: "42", comment: %{"user" => %{"login" => @bot}}},
                 issue_number: "42",
                 actor: @bot
               )

      assert_receive {:event, _}, 500
    end

    test "a quote-reply that inherits the agent's marker reads as human" do
      # GitHub's "Quote reply" copies the body verbatim, HTML comments included.
      # Quoting an agent to disagree with it is the ordinary review gesture, and
      # must not be read as the agent talking to itself.
      :ok = Exchange.subscribe("ticket.42.issue.commented")

      quoted = """
      > Rework applied, pushed as 1a2b3c4.
      >
      > #{AgentMarker.marker()}

      That is not what I asked for — revert it.
      """

      assert {:ok, _id, _count} =
               Publisher.publish("ticket.42.issue.commented", comment(quoted),
                 issue_number: "42",
                 actor: @bot
               )

      assert_receive {:event, _}, 500
    end

    test "the sanitizer's authorship record survives its own HTML-comment stripping" do
      # `Sanitizer.github_payload/2` deletes HTML comments as hidden-instruction
      # carriers, so on the CommandScan path the marker is gone from the body by
      # the time the gate runs. The pre-strip record is what keeps the self-loop
      # closed there.
      body = "/aiur rerun the failing job\n\n" <> AgentMarker.marker()
      payload = Sanitizer.github_payload(%{issue_number: "42", comment: %{"body" => body}}, @bot)

      refute payload.comment["body"] =~ "aiur:agent-authored"
      assert payload.aiur_authored? == true

      assert :filtered =
               Publisher.publish("ticket.42.pr.review_comment", payload,
                 issue_number: "42",
                 actor: @bot,
                 bypass_contamination: true
               )
    end

    test "a sanitized human comment still reaches the agent" do
      :ok = Exchange.subscribe("ticket.42.pr.review_comment")

      payload =
        Sanitizer.github_payload(
          %{issue_number: "42", comment: %{"body" => "/aiur rerun the failing job"}},
          @bot
        )

      assert payload.aiur_authored? == false

      assert {:ok, _id, _count} =
               Publisher.publish("ticket.42.pr.review_comment", payload,
                 issue_number: "42",
                 actor: @bot,
                 bypass_contamination: true
               )

      assert_receive {:event, _}, 500
    end

    test "a bodyless event from the daemon login is still suppressed on login alone" do
      # No human can author a push into the daemon's own event stream, so there
      # is no ambiguity for a marker to resolve and requiring one would
      # republish every self-emitted event.
      assert :filtered = Publisher.publish("ticket.42.branch.push", %{}, actor: @bot)
    end
  end

  describe "separate-account mode" do
    setup do
      configure!("separate_account")
      :ok
    end

    test "the agent's comment is suppressed on the login, with no marker present" do
      :ok = Exchange.subscribe("ticket.42.issue.commented")

      assert :filtered =
               Publisher.publish(
                 "ticket.42.issue.commented",
                 comment("Rework applied, pushed as 1a2b3c4."),
                 issue_number: "42",
                 actor: @bot
               )

      refute_receive {:event, _}, 100
    end

    test "a comment from any other login is delivered" do
      :ok = Exchange.subscribe("ticket.42.issue.commented")

      assert {:ok, _id, _count} =
               Publisher.publish("ticket.42.issue.commented", comment("Please rebase."),
                 issue_number: "42",
                 actor: "its-everdred"
               )

      assert_receive {:event, _}, 500
    end
  end

  describe "mode resolution" do
    test "an install with no identity_mode key behaves as separate-account" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_bot_account: @bot
      )

      assert GitHubConfig.identity_mode() == :separate_account
      refute GitHubConfig.single_account?()

      assert :filtered =
               Publisher.publish("ticket.42.issue.commented", comment("anything at all"),
                 issue_number: "42",
                 actor: @bot
               )
    end

    test "single_account is read from config, not inferred" do
      configure!("single_account")
      assert GitHubConfig.identity_mode() == :single_account
      assert GitHubConfig.single_account?()
    end
  end
end
