defmodule Mix.Tasks.Aiur.CostReportTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Aiur.CostReport

  describe "parse_args/1" do
    test "accepts --ticket, --build, --json, --state-dir" do
      assert {:ok, parsed} = CostReport.parse_args(["--ticket", "930", "--json"])
      assert parsed.ticket == "930"
      assert parsed.json == true

      assert {:ok, parsed} = CostReport.parse_args(["--build", "analytics-optimizations"])
      assert parsed.build == "analytics-optimizations"
    end

    test "rejects unknown options and positional arguments" do
      assert {:error, message} = CostReport.parse_args(["--nope"])
      assert message =~ "unknown options"

      assert {:error, message} = CostReport.parse_args(["surprise"])
      assert message =~ "unexpected arguments"
    end

    test "--help returns the usage doc" do
      assert {:help, usage} = CostReport.parse_args(["--help"])
      assert usage =~ "cost_report"
    end
  end

  describe "ticket_identity/1" do
    test "builds a joinable GitHub identity for the tracked repository" do
      repo = Aiur.GitHub.Config.repo()
      [owner, name] = String.split(repo, "/")

      assert {:ok, identity} = CostReport.ticket_identity("930")
      assert Aiur.TrackerIdentity.github_key(identity) == {:github, owner, name, "930"}
    end
  end
end
