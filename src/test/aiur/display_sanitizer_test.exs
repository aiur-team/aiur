defmodule Aiur.DisplaySanitizerTest do
  use ExUnit.Case, async: true

  alias Aiur.DisplaySanitizer

  # Future-regression guards for existing behavior; this move changes no sanitization rules.
  test "sanitize/2 rejects input longer than the byte limit" do
    assert DisplaySanitizer.sanitize(String.duplicate("a", 11), 10) == :error
  end

  test "sanitize/2 rejects invalid UTF-8 and non-binary input" do
    assert DisplaySanitizer.sanitize(<<0xFF>>, 10) == :error
    assert DisplaySanitizer.sanitize(nil, 10) == :error
  end

  test "sanitize_projection/3 reports truncation" do
    assert DisplaySanitizer.sanitize_projection("abcdef", 3) == {:ok, "abc", true}
  end

  test "sanitize_projection/3 redacts an environment assignment when asked" do
    assert DisplaySanitizer.sanitize_projection("FOO_VALUE=abc123", 100) == {:ok, "FOO_VALUE=abc123", false}

    assert DisplaySanitizer.sanitize_projection("FOO_VALUE=abc123", 100, redact_environment: true) ==
             {:ok, "[REDACTED:env]", false}

    assert DisplaySanitizer.sanitize_projection("FOO_TOKEN=abc123", 100, redact_environment: true) ==
             {:ok, "[REDACTED:credential]", false}
  end

  test "sanitize_projection/3 refuses input over :input_byte_limit" do
    assert DisplaySanitizer.sanitize_projection("abcdef", 100, input_byte_limit: 5) == :error
  end
end
