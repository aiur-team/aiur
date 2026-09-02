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

  alias Aiur.Events.{Exchange, Publisher}
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
