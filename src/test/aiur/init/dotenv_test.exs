defmodule Aiur.Init.DotenvTest do
  use ExUnit.Case

  alias Aiur.Init.Dotenv

  describe "parse/1" do
    test "parses key=value pairs, dropping comments, blanks, and empty values" do
      content = "A=1\n# comment\n\nB=\"x\"\nC='y'\nEMPTY=\n"
      result = Dotenv.parse(content)
      assert result == [{"A", "1"}, {"B", "x"}, {"C", "y"}]
    end

    test "line with no = yields no pair" do
      result = Dotenv.parse("NOTAPAIR\n")
      assert result == []
    end

    test "can retain empty values when callers need to detect key presence" do
      assert Dotenv.parse("GITHUB_TOKEN=\n", include_empty: true) == [{"GITHUB_TOKEN", ""}]
    end
  end

  describe "load/0" do
    @tag :not_async
    test "loads machine token only and respects dotenv precedence" do
      dir = Aiur.TestSupport.tmp_root!("dotenv-test")
      home = Path.join(dir, "home")
      File.mkdir_p!(Path.join(home, ".aiur"))
      File.write!(Path.join(home, ".aiur/.env"), "GITHUB_TOKEN=machine-token\n")

      with_isolated_env(dir, home, %{}, fn ->
        File.cd!(dir, fn -> Dotenv.load() end)
        assert System.get_env("GITHUB_TOKEN") == "machine-token"
      end)

      dir = Aiur.TestSupport.tmp_root!("dotenv-test")
      home = Path.join(dir, "home")
      File.mkdir_p!(Path.join(home, ".aiur"))
      File.write!(Path.join(dir, ".env"), "GITHUB_TOKEN=repo-token\n")
      File.write!(Path.join(home, ".aiur/.env"), "GITHUB_TOKEN=machine-token\nGITHUB_APP_ID=machine-app\n")

      with_isolated_env(dir, home, %{}, fn ->
        File.cd!(dir, fn -> Dotenv.load() end)
        assert System.get_env("GITHUB_TOKEN") == "repo-token"
        assert System.get_env("GITHUB_APP_ID") == nil
      end)

      dir = Aiur.TestSupport.tmp_root!("dotenv-test")
      home = Path.join(dir, "home")
      File.mkdir_p!(Path.join(home, ".aiur"))
      File.write!(Path.join(dir, ".env"), "GITHUB_TOKEN=repo-token\n")
      File.write!(Path.join(home, ".aiur/.env"), "GITHUB_TOKEN=machine-token\n")

      with_isolated_env(dir, home, %{"GITHUB_TOKEN" => "shell-token"}, fn ->
        File.cd!(dir, fn -> Dotenv.load() end)
        assert System.get_env("GITHUB_TOKEN") == "shell-token"
      end)
    end

    @tag :not_async
    test "local token excludes a machine App id and environment-only mode skips files" do
      dir = Aiur.TestSupport.tmp_root!("dotenv-test")
      home = Path.join(dir, "home")
      File.mkdir_p!(Path.join(home, ".aiur"))
      File.write!(Path.join(dir, ".env"), "GITHUB_TOKEN=repo-token\n")
      File.write!(Path.join(home, ".aiur/.env"), "GITHUB_APP_ID=machine-app\n")

      with_isolated_env(dir, home, %{}, fn ->
        File.cd!(dir, fn -> Dotenv.load() end)
        assert System.get_env("GITHUB_APP_ID") == nil
      end)

      dir = Aiur.TestSupport.tmp_root!("dotenv-test")
      home = Path.join(dir, "home")
      File.mkdir_p!(Path.join(home, ".aiur"))
      File.write!(Path.join(dir, ".env"), "FROM_REPO=yes\n")
      File.write!(Path.join(home, ".aiur/.env"), "FROM_MACHINE=yes\n")

      with_isolated_env(dir, home, %{"AIUR_SECRETS_FROM_ENV" => "1"}, fn ->
        File.cd!(dir, fn -> Dotenv.load() end)
        assert System.get_env("FROM_REPO") == nil
        assert System.get_env("FROM_MACHINE") == nil
      end)
    end

    @tag :not_async
    test "blank local GitHub credentials do not block machine GitHub credentials" do
      dir = Aiur.TestSupport.tmp_root!("dotenv-test")
      home = Path.join(dir, "home")
      File.mkdir_p!(Path.join(home, ".aiur"))
      File.write!(Path.join(dir, ".env"), "GITHUB_TOKEN=\n")
      File.write!(Path.join(home, ".aiur/.env"), "GITHUB_APP_ID=machine-app\n")

      with_isolated_env(dir, home, %{}, fn ->
        File.cd!(dir, fn -> Dotenv.load() end)
        assert System.get_env("GITHUB_APP_ID") == "machine-app"
      end)
    end
  end

  defp with_isolated_env(dir, home, env, fun) do
    keys = ["HOME", "AIUR_SECRETS_FROM_ENV", "GITHUB_TOKEN", "GITHUB_APP_ID", "GITHUB_APP_INSTALLATION_ID", "GITHUB_APP_PRIVATE_KEY_PATH", "GITHUB_APP_PRIVATE_KEY", "FROM_REPO", "FROM_MACHINE"]
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)
    System.put_env("HOME", home)
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn {key, value} -> if value, do: System.put_env(key, value), else: System.delete_env(key) end)
      Aiur.TestCleanup.rm_rf!(dir)
    end
  end
end
