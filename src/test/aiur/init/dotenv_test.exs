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
    test "sets env from file, existing env wins" do
      dir = Aiur.TestSupport.tmp_root!("dotenv-test")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".env"), "LOADED_ONLY=fromfile\nPRESET=fromfile\n")

      System.put_env("PRESET", "fromenv")

      on_exit(fn ->
        System.delete_env("LOADED_ONLY")
        System.delete_env("PRESET")
        File.rm_rf!(dir)
      end)

      File.cd!(dir, fn -> Dotenv.load() end)

      assert System.get_env("LOADED_ONLY") == "fromfile"
      assert System.get_env("PRESET") == "fromenv"
    end
  end
end
