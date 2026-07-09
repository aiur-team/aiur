defmodule Aiur.Init.MigrationTest do
  use ExUnit.Case, async: true

  alias Aiur.Init.Migration

  setup do
    repo = Path.join(System.tmp_dir!(), "aiur-migration-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["config", "user.name", "Test User"])
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, repo: repo, legacy: Path.join(repo, ".aiurconfig"), new: Path.join([repo, ".aiur", "config"])}
  end

  test "migrates legacy config pointers and examples", %{repo: repo, legacy: legacy, new: new} do
    File.write!(legacy, "hooks_file: .aiurhooks\nprompt_file: AIUR.md\n")
    File.write!(Path.join(repo, ".aiurhooks"), "hooks\n")
    File.write!(Path.join(repo, "AIUR.md"), "prompt\n")
    File.write!(Path.join(repo, ".aiurconfig.example"), "config example\n")
    File.write!(Path.join(repo, ".aiurhooks.example"), "hooks example\n")
    File.write!(Path.join(repo, "AIUR.md.example"), "prompt example\n")

    assert {:ok, %{moved: moved}} = Migration.migrate_layout(%{legacy_config: legacy, new_config: new, ignore: false})

    assert new in moved
    assert File.read!(new) == "hooks_file: hooks\nprompt_file: prompt.md\n"
    assert File.read!(Path.join([repo, ".aiur", "hooks"])) == "hooks\n"
    assert File.read!(Path.join([repo, ".aiur", "prompt.md"])) == "prompt\n"
    assert File.read!(Path.join([repo, ".aiur", "examples", "config.example"])) == "config example\n"
    refute File.exists?(legacy)
    refute File.exists?(Path.join(repo, ".aiurhooks"))
    refute File.exists?(Path.join(repo, "AIUR.md"))
  end

  test "leaves pointer outside repo in place", %{repo: repo, legacy: legacy, new: new} do
    outside = Path.join(System.tmp_dir!(), "aiur-outside-#{System.unique_integer([:positive])}.md")
    File.write!(outside, "shared prompt\n")
    File.write!(legacy, "hooks_file: .aiurhooks\nprompt_file: #{outside}\n")
    File.write!(Path.join(repo, ".aiurhooks"), "hooks\n")

    assert {:ok, _} = Migration.migrate_layout(%{legacy_config: legacy, new_config: new, ignore: false})

    assert File.read!(new) == "hooks_file: hooks\nprompt_file: #{outside}\n"
    refute File.exists?(Path.join([repo, ".aiur", "prompt.md"]))
    assert File.exists?(outside)
    File.rm!(outside)
  end

  test "ignore option appends .aiur to gitignore", %{repo: repo, legacy: legacy, new: new} do
    File.write!(legacy, "hooks_file: .aiurhooks\n")
    File.write!(Path.join(repo, ".aiurhooks"), "hooks\n")

    assert {:ok, _} = Migration.migrate_layout(%{legacy_config: legacy, new_config: new, ignore: true})
    assert File.read!(Path.join(repo, ".gitignore")) == ".aiur/\n"
  end

  defp git!(repo, args) do
    assert {_out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
  end
end
