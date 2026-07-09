defmodule Aiur.PaneManager.GenericOpenTest do
  use ExUnit.Case, async: true

  alias Aiur.PaneManager.GenericOpen

  describe "wrap_with_unique_node/2" do
    test "produces env ERL_AFLAGS with name, proto_dist, and inet_dist flags" do
      result = GenericOpen.wrap_with_unique_node("mycommand", "issue-1")

      assert result =~ ~r/^env ERL_AFLAGS="/
      assert result =~ ~r/-name pane-issue-1-[A-Za-z0-9]+@127\.0\.0\.1/
      assert result =~ "-proto_dist inet_tcp"
      assert result =~ "-kernel inet_dist_use_interface {127,0,0,1}"
      assert String.ends_with?(result, "\" mycommand")
    end

    test "sanitizes non-alphanumeric/underscore/dash characters to dash" do
      result = GenericOpen.wrap_with_unique_node("cmd", "issue 1/foo.bar")

      assert result =~ ~r/-name pane-issue-1-foo-bar-[A-Za-z0-9]+@127\.0\.0\.1/
    end

    @tag :capture_log
    test "with AIUR_ERLANG_COOKIE env var includes -setcookie <cookie>" do
      System.put_env("AIUR_ERLANG_COOKIE", "testcookie123")

      on_exit(fn -> System.delete_env("AIUR_ERLANG_COOKIE") end)

      result = GenericOpen.wrap_with_unique_node("cmd", "issue-1")
      assert result =~ "-setcookie testcookie123"
    end

    @tag :capture_log
    test "without AIUR_ERLANG_COOKIE env var does not use the env cookie" do
      System.delete_env("AIUR_ERLANG_COOKIE")

      on_exit(fn -> System.delete_env("AIUR_ERLANG_COOKIE") end)

      result = GenericOpen.wrap_with_unique_node("cmd", "issue-1")
      # No env-based cookie should appear (file cookie may still appear)
      refute result =~ "-setcookie testcookie123"
    end
  end

  describe "read_erlang_cookie/0" do
    @tag :capture_log
    test "returns env cookie when AIUR_ERLANG_COOKIE is set" do
      System.put_env("AIUR_ERLANG_COOKIE", "mycookie")

      on_exit(fn -> System.delete_env("AIUR_ERLANG_COOKIE") end)

      assert GenericOpen.read_erlang_cookie() == "mycookie"
    end

    test "returns a binary or nil when AIUR_ERLANG_COOKIE is not set" do
      System.delete_env("AIUR_ERLANG_COOKIE")
      result = GenericOpen.read_erlang_cookie()
      assert is_nil(result) or is_binary(result)
    end
  end
end
