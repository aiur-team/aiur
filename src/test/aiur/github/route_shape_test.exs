defmodule Aiur.GitHub.RouteShapeTest do
  @moduledoc """
  The request log's route shapes are a closed vocabulary, and the property the
  module exists for is that no input byte can reach the output. The security
  test leads: a URL carrying a token in a query parameter, a newline, a CR, or
  path-traversal segments must produce a member of the fixed constant set and
  never echo any of those bytes.
  """

  use ExUnit.Case, async: true

  alias Aiur.GitHub.RouteShape

  describe "log_shape/1" do
    test "names known REST shapes with constants, not URL bytes" do
      assert RouteShape.log_shape("https://api.github.com/repos/o/r/issues/2073/timeline?per_page=100") ==
               "issue_timeline"

      assert RouteShape.log_shape("https://api.github.com/repos/o/r/issues/2073/comments?per_page=100") ==
               "issue_comments"

      assert RouteShape.log_shape("https://api.github.com/repos/o/r/issues/2073") == "issue"
      assert RouteShape.log_shape("https://api.github.com/repos/o/r/issues/comments?since=1") == "comment_stream"
      assert RouteShape.log_shape("https://api.github.com/repos/o/r/issues?labels=x&state=open") == "issues"

      assert RouteShape.log_shape("https://api.github.com/repos/o/r/pulls/99/files?per_page=100") == "pull_files"
      assert RouteShape.log_shape("https://api.github.com/repos/o/r/pulls/99/comments") == "pull_comments"
      assert RouteShape.log_shape("https://api.github.com/repos/o/r/pulls/99") == "pull"
      assert RouteShape.log_shape("https://api.github.com/repos/o/r/pulls?state=open") == "pulls"
      assert RouteShape.log_shape("https://api.github.com/repos/o/r/events") == "repo_events"

      assert RouteShape.log_shape("https://api.github.com/repos/o/r/branches/main/protection") ==
               "branch_protection"

      assert RouteShape.log_shape("https://api.github.com/repos/o/r/branches/main") == "branches"
      assert RouteShape.log_shape("https://api.github.com/repos/o/r/contents/.github/workflows?ref=main") == "contents"
      assert RouteShape.log_shape("https://api.github.com/repos/o/r/actions/workflows?per_page=100") == "actions_workflows"
      assert RouteShape.log_shape("https://api.github.com/repos/o/r/rulesets?includes_parents=true") == "rulesets"
      assert RouteShape.log_shape("https://api.github.com/repos/o/r") == "repo"
      assert RouteShape.log_shape("https://api.github.com/repos/o/r/teams") == "repos_other"
      assert RouteShape.log_shape("https://api.github.com/orgs/o/teams") == "orgs"
      assert RouteShape.log_shape("https://api.github.com/graphql") == "graphql"
      assert RouteShape.log_shape("https://api.github.com/rate_limit") == "rate_limit"
      assert RouteShape.log_shape("https://api.github.com/user") == "user"
    end

    test "accepts a request map as well as a bare URL" do
      assert RouteShape.log_shape(%{url: "https://api.github.com/repos/o/r/issues/7"}) == "issue"
    end

    test "collapses every number so one endpoint family is one constant" do
      assert RouteShape.log_shape("https://api.github.com/repos/o/r/issues/2073") ==
               RouteShape.log_shape("https://api.github.com/repos/o/r/issues/1999")
    end

    test "a URL matching no known template is the other constant" do
      assert RouteShape.log_shape("https://api.github.com/search/issues?q=foo") == "other"
      assert RouteShape.log_shape("https://api.github.com/not/a/known/path") == "other"
      assert RouteShape.log_shape("https://api.github.com") == "other"
      assert RouteShape.log_shape("not a url") == "other"
      assert RouteShape.log_shape(nil) == "other"
    end

    test "hostile URLs map to a known constant and never to input bytes" do
      token = "ghp_" <> String.duplicate("A1", 20)

      hostile = [
        # Path traversal — `..` must never reach the output.
        "https://api.github.com/repos/o/r/../../../../etc/passwd",
        "https://api.github.com/../../../../etc/passwd",
        # A newline trying to forge a second TSV row.
        "https://api.github.com/repos/o/r/issues/1\n<script>alert(1)</script>",
        # A CR trying to forge a second row.
        "https://api.github.com/repos/o/r/issues/1/comments\r\nX-Injected: yes",
        # A token-shaped query parameter on every surface.
        "https://api.github.com/repos/o/r/issues?access_token=#{token}",
        "https://api.github.com/repos/o/r/issues/1/comments?token=#{token}",
        "https://api.github.com/graphql?authorization=#{token}",
        "https://api.github.com/repos/o/r/actions/workflows?private_key=#{token}"
      ]

      for url <- hostile do
        shape = RouteShape.log_shape(url)
        assert shape in RouteShape.known_shapes(), "hostile URL #{inspect(url)} escaped the closed vocabulary: #{inspect(shape)}"
        refute String.contains?(shape, token), "token leaked into #{inspect(shape)} from #{inspect(url)}"
        refute String.contains?(shape, ".."), "path traversal leaked into #{inspect(shape)}"
        refute String.contains?(shape, "\n"), "newline leaked into #{inspect(shape)}"
        refute String.contains?(shape, "\r"), "CR leaked into #{inspect(shape)}"
      end
    end

    test "known_shapes is finite and contains the unrecognised constant" do
      assert "other" in RouteShape.known_shapes()
      assert is_list(RouteShape.known_shapes())
      assert RouteShape.known_shapes() == Enum.uniq(RouteShape.known_shapes())
    end
  end
end
