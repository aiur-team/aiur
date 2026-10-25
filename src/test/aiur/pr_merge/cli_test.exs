defmodule Aiur.PrMerge.CLITest do
  use ExUnit.Case, async: true
  @sha String.duplicate("a", 40)

  test "merge needs an explicit full reviewed SHA and accepts repeated inherited checks" do
    for args <- [[], ["merge"], ["merge", "1"], ["merge", "1", "--reviewed-sha", "abc"], ["merge", "0", "--reviewed-sha", @sha], ["merge", "1", "--reviewed-sha", @sha, "--unknown"]] do
      assert {:error, usage} = Aiur.PrMergeCLI.parse(args)
      assert usage =~ "Usage: aiur pr merge"
    end

    assert {:ok, %{number: 1, reviewed_sha: @sha, dry_run: true, inherited: ["lint", "coverage"]}} =
             Aiur.PrMergeCLI.parse(["merge", "1", "--reviewed-sha", @sha, "--dry-run", "--inherited", "lint", "--inherited", "coverage"])
  end
end
