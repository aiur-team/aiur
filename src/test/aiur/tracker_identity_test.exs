defmodule Aiur.TrackerIdentityTest do
  use ExUnit.Case, async: true

  alias Aiur.{Issue, TrackerIdentity}

  @configured {"owner", "repo"}

  test "builds a versioned identity from configured repository and provider node ID" do
    issue = %{"node_id" => "I_kwDOExample", "number" => 42, "title" => "Ticket 42"}

    assert {:ok, identity} = TrackerIdentity.from_github(issue, @configured, @configured)
    assert identity.version == 1
    assert identity.status == :joinable
    assert identity.kind == :github
    assert identity.owner == "owner"
    assert identity.repository == "repo"
    assert identity.provider_id == "I_kwDOExample"
    assert identity.identifier == "42"
    assert TrackerIdentity.joinable?(identity)
    assert Jason.decode!(Jason.encode!(identity))["provider_id"] == "I_kwDOExample"
  end

  test "keeps same-number issues from different repositories distinct" do
    issue = %{"node_id" => "I_kwDOExample", "number" => 42}

    assert {:ok, first} = TrackerIdentity.from_github(issue, {"owner", "repo-one"}, {"owner", "repo-one"})
    assert {:ok, second} = TrackerIdentity.from_github(issue, {"owner", "repo-two"}, {"owner", "repo-two"})

    assert first.identifier == second.identifier
    refute first == second
  end

  test "rejects request and response repositories that differ from configuration" do
    issue = %{"node_id" => "I_kwDOExample", "number" => 42, "repository_url" => "https://api.github.com/repos/other/repo"}

    assert {:error, :repository_mismatch} = TrackerIdentity.from_github(issue, @configured, @configured)
    assert {:error, :repository_mismatch} = TrackerIdentity.from_github(Map.delete(issue, "repository_url"), @configured, {"other", "repo"})
  end

  test "rejects missing or malformed provider identity without deriving one from locators" do
    for issue <- [
          %{"number" => 42},
          %{"node_id" => " ", "number" => 42},
          %{"node_id" => 42, "number" => 42},
          %{"node_id" => "I_kwDOExample", "number" => 0},
          %{
            "node_id" => "I_kwDOExample",
            "number" => "ticket.42",
            "title" => "Ticket 42",
            "topic" => "ticket.42",
            "workspace_path" => "/workspaces/owner/repo/42",
            "active_workflow" => "owner/repo"
          }
        ] do
      refute match?({:ok, _}, TrackerIdentity.from_github(issue, @configured, @configured))
    end
  end

  test "legacy and explicitly unjoinable identities never join" do
    legacy = TrackerIdentity.unjoinable(:legacy)
    mismatch = TrackerIdentity.unjoinable(:repository_mismatch, owner: "owner", repository: "repo", identifier: 42)
    malformed = %TrackerIdentity{status: :joinable, kind: :github, owner: "", repository: "repo", provider_id: "number-42", identifier: "42"}

    refute TrackerIdentity.joinable?(nil)
    assert Issue.tracker_identity(%Issue{id: "linear-id", identifier: "LIN-42"}) == nil
    refute TrackerIdentity.joinable?(legacy)
    refute TrackerIdentity.joinable?(mismatch)
    refute TrackerIdentity.joinable?(malformed)
    assert mismatch.identifier == "42"
  end
end
