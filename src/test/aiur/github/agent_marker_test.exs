defmodule Aiur.GitHub.AgentMarkerTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.AgentMarker
  alias Aiur.Workflow

  defp configure!(mode) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur",
      tracker_bot_account: "aiur-bot",
      tracker_identity_mode: mode
    )
  end

  describe "marked?/1" do
    test "recognizes only the exact marker" do
      assert AgentMarker.marked?("done\n\n" <> AgentMarker.marker())
      refute AgentMarker.marked?("done")
      refute AgentMarker.marked?("<!-- aiur:agent -->")
      refute AgentMarker.marked?("aiur:agent-authored")
    end

    test "an unreadable body cannot prove Aiur wrote it" do
      refute AgentMarker.marked?(nil)
      refute AgentMarker.marked?(%{"body" => "x"})
      refute AgentMarker.marked?(123)
    end
  end

  describe "stamp/1" do
    test "separate-account mode leaves every body byte-for-byte unchanged" do
      configure!("separate_account")
      assert AgentMarker.stamp("Rework applied.") == "Rework applied."
    end

    test "single-account mode appends the marker" do
      configure!("single_account")
      stamped = AgentMarker.stamp("Rework applied.")

      assert AgentMarker.marked?(stamped)
      assert String.starts_with?(stamped, "Rework applied.")
    end

    test "single-account stamping is idempotent" do
      configure!("single_account")
      once = AgentMarker.stamp("Rework applied.")

      assert AgentMarker.stamp(once) == once
    end

    test "the marker renders to nothing: it is an HTML comment" do
      # A visible marker would show up in every agent comment an operator
      # reads. GitHub stores HTML comments verbatim and renders them away.
      assert String.starts_with?(AgentMarker.marker(), "<!--")
      assert String.ends_with?(AgentMarker.marker(), "-->")
      refute String.contains?(AgentMarker.marker(), "\n")
    end
  end
end
