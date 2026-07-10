defmodule Aiur.ShellTest do
  use ExUnit.Case, async: true

  alias Aiur.Shell

  @tricky_inputs [
    "plain",
    "two words",
    ~s(double "quoted" text),
    "it's",
    "'",
    "''",
    "$HOME and ${PATH}",
    "`id`",
    "line one\nline two",
    "mix 'of' \"all\" $THINGS `here`\nand a newline",
    ""
  ]

  describe "escape/1" do
    test "wraps in single quotes and splices embedded single quotes with the canonical dialect" do
      assert Shell.escape("plain") == "'plain'"
      assert Shell.escape("two words") == "'two words'"
      assert Shell.escape(~s(say "hi")) == ~s('say "hi"')
      assert Shell.escape("it's") == ~s('it'"'"'s')
      assert Shell.escape("$HOME") == "'$HOME'"
      assert Shell.escape("`id`") == "'`id`'"
      assert Shell.escape("a\nb") == "'a\nb'"
      assert Shell.escape("") == "''"
    end

    test "round-trips every tricky input through a real POSIX shell byte-for-byte" do
      for value <- @tricky_inputs do
        {out, 0} = System.cmd("sh", ["-c", "printf %s " <> Shell.escape(value)])
        assert out == value
      end
    end
  end

  describe "escape/2 with fast_path: true" do
    test "returns safe-charset values unquoted" do
      assert Shell.escape("abc-123", fast_path: true) == "abc-123"
      assert Shell.escape("http://127.0.0.1:1234", fast_path: true) == "http://127.0.0.1:1234"
      assert Shell.escape("a_b/c:d.e,f=g@h%i+j", fast_path: true) == "a_b/c:d.e,f=g@h%i+j"
    end

    test "quotes anything outside the safe charset, including the empty string" do
      assert Shell.escape("session one", fast_path: true) == "'session one'"
      assert Shell.escape("it's", fast_path: true) == ~s('it'"'"'s')
      assert Shell.escape("", fast_path: true) == "''"
    end

    test "fast_path: false behaves exactly like escape/1" do
      assert Shell.escape("abc", fast_path: false) == "'abc'"
    end
  end
end
