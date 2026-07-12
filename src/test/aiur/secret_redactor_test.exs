defmodule Aiur.SecretRedactorTest do
  use ExUnit.Case, async: true

  alias Aiur.SecretRedactor

  test "redacts each known credential pattern" do
    samples = [
      {"sk-" <> String.duplicate("a", 20), "[REDACTED:sk]"},
      {"github_pat_" <> String.duplicate("a", 20), "[REDACTED:github_pat]"},
      {"ghp_" <> String.duplicate("a", 36), "[REDACTED:ghp]"},
      {"gho_" <> String.duplicate("a", 36), "[REDACTED:gho]"},
      {"ghu_" <> String.duplicate("a", 36), "[REDACTED:ghu]"},
      {"ghs_" <> String.duplicate("a", 36), "[REDACTED:ghs]"},
      {"xoxb-123-456-abc", "[REDACTED:xoxb]"},
      {"AKIA" <> String.duplicate("A", 16), "[REDACTED:aws]"},
      {"ASIA" <> String.duplicate("A", 16), "[REDACTED:aws_session]"},
      {"AIza" <> String.duplicate("A", 35), "[REDACTED:google]"}
    ]

    for {secret, marker} <- samples do
      assert SecretRedactor.redact("before #{secret} after") == "before #{marker} after"
    end
  end

  test "leaves ordinary text untouched" do
    text = "no secrets here, just a normal sentence."
    assert SecretRedactor.redact(text) == text
  end

  test "redacts multiple distinct secrets in one string" do
    text = "key1=sk-#{String.duplicate("a", 20)} key2=AKIA#{String.duplicate("A", 16)}"
    assert SecretRedactor.redact(text) == "key1=[REDACTED:sk] key2=[REDACTED:aws]"
  end

  test "is idempotent" do
    text = "leaked: ghp_#{String.duplicate("a", 36)}"
    once = SecretRedactor.redact(text)
    assert SecretRedactor.redact(once) == once
  end
end
