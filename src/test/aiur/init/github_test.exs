defmodule Aiur.Init.GitHubTest do
  use ExUnit.Case

  alias Aiur.Init.GitHub

  describe "parse_repo/1" do
    test "parses SSH URL" do
      assert GitHub.parse_repo("git@github.com:o/r.git") == "o/r"
    end

    test "parses HTTPS URL with .git suffix" do
      assert GitHub.parse_repo("https://github.com/o/r.git") == "o/r"
    end

    test "parses HTTPS URL without .git suffix" do
      assert GitHub.parse_repo("https://github.com/o/r") == "o/r"
    end

    test "returns nil for garbage input" do
      assert GitHub.parse_repo("garbage") == nil
    end
  end

  describe "parse_owner_repo/1" do
    test "parses owner/name string" do
      assert GitHub.parse_owner_repo("o/r") == {:ok, {"o", "r"}}
    end

    test "returns error for nil" do
      {:error, msg} = GitHub.parse_owner_repo(nil)
      assert msg =~ ".aiur/config"
    end

    test "returns error for non-slash string" do
      {:error, msg} = GitHub.parse_owner_repo("nope")
      assert msg =~ ".aiur/config"
    end
  end

  describe "ensure_ci_readiness/3" do
    test "explains the administration permission needed to inspect a CI gate" do
      io = %{puts: fn _ -> :ok end, confirm: fn _, _ -> false end}
      deps = %{check_ci_readiness: fn _ -> {:error, {:github, :http, %{status: 403}}} end, detect_repo: fn -> "o/r" end}

      assert {:error, message} = GitHub.ensure_ci_readiness(io, deps, %{kind: "github", repo: "o/r"})
      assert message =~ "Administration: Read-only"
    end
  end

  describe "label_error_message/1" do
    test "403 mentions token scope" do
      msg = GitHub.label_error_message({:github_api_status, 403, "agent:todo"})
      assert msg =~ "403"
      assert msg =~ "scope"
    end

    test "404 mentions .aiur/config" do
      msg = GitHub.label_error_message({:github_api_status, 404, "agent:todo"})
      assert msg =~ "404"
      assert msg =~ ".aiur/config"
    end

    test "other status returns generic message" do
      msg = GitHub.label_error_message({:github_api_status, 500, "x"})
      assert msg =~ "500"
    end

    test "request error mentions reason" do
      msg = GitHub.label_error_message({:github_api_request, :timeout})
      assert msg =~ "timeout"
    end

    test "unknown term is inspected" do
      msg = GitHub.label_error_message(:something_else)
      assert msg =~ "something_else"
    end
  end

  describe "require_github_token/0" do
    @tag :not_async
    test "returns error when GITHUB_TOKEN not set" do
      System.delete_env("GITHUB_TOKEN")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)
      {:error, msg} = GitHub.require_github_token()
      assert msg =~ ".env"
    end

    @tag :not_async
    test "returns ok when GITHUB_TOKEN is set" do
      System.put_env("GITHUB_TOKEN", "tok")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)
      assert GitHub.require_github_token() == {:ok, "tok"}
    end
  end

  describe "detect_bot_account/1" do
    @tag :not_async
    test "returns nil when no GITHUB_TOKEN is set (never calls the viewer lookup)" do
      System.delete_env("GITHUB_TOKEN")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

      request_fun = fn _req -> flunk("viewer lookup must not run without a token") end
      assert GitHub.detect_bot_account(request_fun) == nil
    end

    @tag :not_async
    test "returns nil on a viewer-lookup failure without surfacing the token" do
      System.put_env("GITHUB_TOKEN", "ghp_supersecret")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

      request_fun = fn _req -> {:error, :boom} end
      assert GitHub.detect_bot_account(request_fun) == nil
    end

    @tag :not_async
    test "returns nil when the request raises rather than crashing" do
      System.put_env("GITHUB_TOKEN", "ghp_supersecret")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

      request_fun = fn _req -> raise "network down" end
      assert GitHub.detect_bot_account(request_fun) == nil
    end

    @tag :not_async
    test "normalizes the resolved viewer login" do
      System.put_env("GITHUB_TOKEN", "ghp_supersecret")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

      request_fun = fn _req ->
        {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "Its-AppleKid"}}}}}
      end

      assert GitHub.detect_bot_account(request_fun) == "its-applekid"
    end
  end

  describe "detect_repo/0" do
    test "returns owner/name from git remote" do
      dir = System.tmp_dir!() |> Path.join("detect-repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      System.cmd("git", ["init"], cd: dir)
      System.cmd("git", ["remote", "add", "origin", "git@github.com:o/r.git"], cd: dir)

      result = File.cd!(dir, fn -> GitHub.detect_repo() end)
      assert result == "o/r"
    end

    test "returns nil when no origin remote" do
      dir = System.tmp_dir!() |> Path.join("detect-repo-noremote-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      System.cmd("git", ["init"], cd: dir)

      result = File.cd!(dir, fn -> GitHub.detect_repo() end)
      assert result == nil
    end
  end

  describe "list_repo_labels/1 and create_labels/2" do
    test "list_repo_labels returns {:ok, []} for non-github tracker" do
      assert GitHub.list_repo_labels(%{kind: "memory"}) == {:ok, []}
    end

    test "create_labels returns :ok for non-github tracker" do
      assert GitHub.create_labels(%{kind: "memory"}, ["agent:todo"]) == :ok
    end
  end
end
