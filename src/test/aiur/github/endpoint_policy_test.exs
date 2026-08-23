defmodule Aiur.GitHub.EndpointPolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.{Budget, EndpointPolicy}

  # Representative URL paths for the families the daemon's Budget path can
  # classify from a request URL. `search` is a ledger family the guard produces
  # (from the `gh search` subcommand) but no daemon request URL resolves to it,
  # so it is covered by the table walk, not by a URL here.
  @url_families [
    {"rate_limit", "/rate_limit", "none", false},
    {"graphql", "/graphql", "graphql", true},
    {"pulls", "/repos/owner/repo/pulls/1477", "core", true},
    {"issues", "/repos/owner/repo/issues/1477/comments", "core", true},
    {"actions", "/repos/owner/repo/actions/runs/123", "core", true},
    {"labels", "/repos/owner/repo/labels/bug", "core", true},
    {"rest", "/repos/owner/repo", "core", true}
  ]

  test "every enumerated family has a resource and a billable decision" do
    families = EndpointPolicy.families()
    assert is_list(families) and families != []
    assert length(families) == length(Enum.uniq_by(families, &elem(&1, 0)))

    for {family, resource, billable} <- EndpointPolicy.families() do
      # A family added without a decision fails here: resource must be a known
      # pool (or `none`), and billable must be an explicit boolean.
      assert family in ["rate_limit", "graphql", "search", "pulls", "issues", "actions", "labels", "comments", "reviews", "rest"]
      assert resource in EndpointPolicy.known_resources()
      assert is_boolean(billable)

      # The accessors and the table row never disagree.
      assert EndpointPolicy.resource_for(family) == resource
      assert EndpointPolicy.billable_for(family) == billable
    end
  end

  test "Budget classifies request URLs through the shared table" do
    for {family, path, resource, billable} <- @url_families do
      request = request(path)

      assert Budget.endpoint_family(request) == family
      assert Budget.request_resource(request) == resource
      assert EndpointPolicy.endpoint_family(path) == family
      assert EndpointPolicy.resource(path) == resource
      assert EndpointPolicy.billable?(path) == billable
      assert EndpointPolicy.free_endpoint?(path) == not billable
    end
  end

  test "a family outside the table falls back to billable rest/core" do
    assert EndpointPolicy.endpoint_family("/not/a/known/path") == "rest"
    assert EndpointPolicy.resource("/not/a/known/path") == "core"
    assert EndpointPolicy.billable?("/not/a/known/path")
    refute EndpointPolicy.free_endpoint?("/not/a/known/path")
  end

  test "rate_limit is the one endpoint free in both subsystems" do
    # Quota's free-endpoint predicate delegates to this table, so the two
    # subsystems cannot disagree about which endpoints GitHub does not meter.
    for {family, _resource, billable} <- EndpointPolicy.families() do
      assert EndpointPolicy.billable_for(family) == billable
    end

    assert EndpointPolicy.free_endpoint?("/rate_limit")
    assert EndpointPolicy.endpoint_family("/rate_limit") == "rate_limit"
    assert EndpointPolicy.resource("/rate_limit") == "none"
    assert Budget.request_resource(request("/rate_limit")) == "none"
    refute EndpointPolicy.free_endpoint?("/repos/owner/repo/issues/1")
  end

  defp request(path), do: %{method: :get, url: "https://api.github.com#{path}", token: "test-token"}
end
