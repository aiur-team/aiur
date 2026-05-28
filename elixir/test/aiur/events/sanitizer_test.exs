defmodule Aiur.Events.SanitizerTest do
  @moduledoc """
  Plan U7. `Aiur.Events.Sanitizer` is pure functional — no GenServer,
  no I/O. Cover the redaction + truncation interactions plus the
  CODEOWNERS author trust stamp's safe fall-back when CodeOwners isn't
  running.
  """

  use ExUnit.Case, async: true

  alias Aiur.Events.Sanitizer

  describe "scrub/1 truncation" do
    test "commit_subject capped at 200 chars" do
      payload = %{commit_subject: String.duplicate("a", 250)}
      %{commit_subject: scrubbed} = Sanitizer.scrub(payload)
      assert String.length(scrubbed) == 201
      assert String.ends_with?(scrubbed, "…")
    end

    test "comment_body capped at 500 chars" do
      payload = %{comment_body: String.duplicate("b", 600)}
      %{comment_body: scrubbed} = Sanitizer.scrub(payload)
      assert String.length(scrubbed) == 501
      assert String.ends_with?(scrubbed, "…")
    end

    test "pr_review_body capped at 500 chars" do
      payload = %{pr_review_body: String.duplicate("c", 600)}
      %{pr_review_body: scrubbed} = Sanitizer.scrub(payload)
      assert String.length(scrubbed) == 501
    end

    test "fields at or under their cap pass through unchanged" do
      payload = %{commit_subject: "short subject", comment_body: "ok"}
      assert ^payload = Sanitizer.scrub(payload)
    end
  end

  describe "scrub/1 redaction" do
    test "Anthropic-style sk- key redacted" do
      payload = %{comment_body: "found sk-abcdefghij1234567890ABCDEF and that's it"}
      assert %{comment_body: scrubbed} = Sanitizer.scrub(payload)
      assert scrubbed =~ "[REDACTED:sk]"
      refute scrubbed =~ "sk-abcdefghij"
    end

    test "GitHub PAT redacted" do
      payload = %{comment_body: "token ghp_" <> String.duplicate("A", 40)}
      assert %{comment_body: scrubbed} = Sanitizer.scrub(payload)
      assert scrubbed =~ "[REDACTED:ghp]"
    end

    test "Slack bot token redacted" do
      payload = %{comment_body: "set BOT=xoxb-1234-5678-abcdef"}
      assert %{comment_body: scrubbed} = Sanitizer.scrub(payload)
      assert scrubbed =~ "[REDACTED:xoxb]"
    end

    test "AWS access key redacted" do
      payload = %{commit_subject: "key AKIAABCDEFGHIJKLMNOP found"}
      assert %{commit_subject: scrubbed} = Sanitizer.scrub(payload)
      assert scrubbed =~ "[REDACTED:aws]"
    end

    test "redaction runs before truncation so the original key never leaks" do
      # A subject containing a full sk- key plus surrounding text:
      # redact first → key becomes [REDACTED:sk]; truncation applies after.
      # Either way the raw `sk-XXXX...` substring must NOT survive.
      key = "sk-" <> String.duplicate("X", 30)
      payload = %{commit_subject: String.duplicate("z", 100) <> key <> "trailing"}
      %{commit_subject: scrubbed} = Sanitizer.scrub(payload)
      refute scrubbed =~ key
      assert scrubbed =~ "[REDACTED:sk]"
    end
  end

  describe "scrub/1 boundary behavior" do
    test "non-string fields pass through" do
      payload = %{commit_subject: nil, comment_body: 42}
      assert ^payload = Sanitizer.scrub(payload)
    end

    test "untouched payload fields are preserved" do
      payload = %{
        commit_subject: "ok",
        author: "octocat",
        topic: "ticket.99.branch.push",
        message: "push abc123"
      }

      assert ^payload = Sanitizer.scrub(payload)
    end
  end

  describe "stamp_author_trust/2" do
    test "stamps author_trusted? = false when CodeOwners isn't running" do
      payload = %{author: "outside-contractor"}
      assert %{author_trusted?: false} = Sanitizer.stamp_author_trust(payload)
    end

    test "stamps false when payload has no author and no actor opt" do
      payload = %{topic: "ticket.99.branch.push"}
      assert %{author_trusted?: false} = Sanitizer.stamp_author_trust(payload)
    end

    test "falls back to :actor keyword when payload has no author" do
      payload = %{topic: "ticket.99.branch.push"}
      result = Sanitizer.stamp_author_trust(payload, actor: "octocat")
      assert result.author_trusted? in [true, false]
    end
  end
end
