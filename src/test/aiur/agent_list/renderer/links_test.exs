defmodule Aiur.AgentList.Renderer.LinksTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.Renderer.Links

  test "ticket_url builds issue URLs for numeric ids only" do
    assert Links.ticket_url("aiur-team/aiur", "830") ==
             "https://github.com/aiur-team/aiur/issues/830"

    assert Links.ticket_url("aiur-team/aiur", "abc") == nil
    assert Links.ticket_url(nil, "830") == nil
  end

  test "osc8 wraps text with the terminal hyperlink escape" do
    assert Links.osc8("https://example.test", "text") ==
             "\e]8;;https://example.test\e\\text\e]8;;\e\\"
  end

  test "link_ticket_id is plain without repo identity" do
    assert Links.link_ticket_id("830", nil) == "830"
  end

  test "wrap_token wraps only the first matching token" do
    assert Links.wrap_token("PR and PR", "PR", "https://example.test") ==
             "\e]8;;https://example.test\e\\PR\e]8;;\e\\ and PR"

    assert Links.wrap_token("PR", "PR", nil) == "PR"
    assert Links.wrap_token("PR", "PR", "") == "PR"
    assert Links.wrap_token("comment", "PR", "https://example.test") == "comment"
  end

  test "pr_link_target prefers html_url then number-derived URL then fallback" do
    assert Links.pr_link_target(%{"pr" => %{"html_url" => "https://pr"}}, "owner/repo", "fallback") ==
             "https://pr"

    assert Links.pr_link_target(%{"pr" => %{"number" => 12}}, "owner/repo", "fallback") ==
             "https://github.com/owner/repo/pull/12"

    assert Links.pr_link_target(%{}, "owner/repo", "fallback") == "fallback"
  end

  test "comment_link_target prefers comment URL, PR URL for review comments, then fallback" do
    assert Links.comment_link_target(
             %{"comment" => %{"html_url" => "https://comment"}},
             "issue.commented",
             "fallback"
           ) == "https://comment"

    assert Links.comment_link_target(
             %{"pr" => %{"html_url" => "https://pr"}},
             "pr.review_comment",
             "fallback"
           ) == "https://pr"

    assert Links.comment_link_target(%{}, "issue.commented", "fallback") == "fallback"
  end
end
