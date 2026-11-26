defmodule Aiur.LocalTestEvidenceTest do
  use ExUnit.Case, async: true
  alias Aiur.LocalTestEvidence

  @head String.duplicate("a", 40)
  @body """
  ## Local tests

  Policy: partial
  Tested head: #{@head}
  Base: origin/main @ #{String.duplicate("b", 40)}
  Selection: changed tests and direct callers
  - `mix test test/aiur/foo_test.exs` -> 42 tests, 0 failures
  - `mix format --check-formatted` -> ok

  ## Next section

  - `not evidence`
  """

  test "parses policy, head, selection and command results within the section" do
    assert {:ok, evidence} = LocalTestEvidence.parse(@body)
    assert evidence.policy == "partial"
    assert evidence.tested_head == @head
    assert evidence.base == "origin/main @ #{String.duplicate("b", 40)}"
    assert evidence.selection == "changed tests and direct callers"

    assert evidence.commands == [
             %{command: "mix test test/aiur/foo_test.exs", result: "42 tests, 0 failures"},
             %{command: "mix format --check-formatted", result: "ok"}
           ]
  end

  test "reports missing section" do
    assert :missing = LocalTestEvidence.parse("## Summary\n\nSome prose.")
  end

  test "rejects short SHA, invalid policy, empty fields and missing command results" do
    for {old, new} <- [
          {@head, "abcdef0"},
          {"Policy: partial", "Policy: maybe"},
          {"Base: origin/main @ #{String.duplicate("b", 40)}", "Base: anything"},
          {"Selection: changed tests and direct callers", "Selection: "},
          {" -> 42 tests, 0 failures", ""},
          {" -> ok", " -> "}
        ] do
      assert {:error, _reason} = LocalTestEvidence.parse(String.replace(@body, old, new))
    end

    assert {:error, _reason} = LocalTestEvidence.parse(String.replace(@body, ~r/^- `.*\n/m, ""))
  end

  test "rejects command bullets split by blank lines or prose, or placed after prose" do
    first = "- `mix test test/aiur/foo_test.exs` -> 42 tests, 0 failures\n"

    # #4507 shape: a second bullet run after a blank line and a prose note.
    # #4502 shape: prose between Selection and the list.
    for replacement <- [
          first <> "\n",
          first <> "Mutation evidence: each case ran in a worktree.\n",
          first <> "\nMutation evidence: each case ran in a worktree.\n\n",
          "\nThe first pre-pr run failed before push.\n\n" <> first
        ] do
      assert {:error, "Local tests command bullets must be one unbroken list directly after Selection: " <> fix} =
               LocalTestEvidence.parse(String.replace(@body, first, replacement))

      assert fix =~ "move notes below the list"
    end
  end

  test "a malformed command bullet error names the line and where notes go" do
    # #4777 shape: a note between the closing backtick and ->.
    body = String.replace(@body, "`mix format --check-formatted` -> ok", "`mix format --check-formatted` (note) -> ok")

    assert {:error, message} = LocalTestEvidence.parse(body)
    assert message =~ "- `mix format --check-formatted` (note) -> ok"
    assert message =~ "Put notes after ->"
  end

  test "accepts notes after the list and a blank line before it" do
    notes = String.replace(@body, "-> ok\n", "-> ok\n\nCI remains authoritative.\n\n```text\n--- aiur pre-pr result ---\n```\n")
    assert {:ok, %{commands: [_, _]}} = LocalTestEvidence.parse(notes)
    assert {:ok, %{commands: [_, _]}} = LocalTestEvidence.parse(String.replace(@body, "direct callers\n", "direct callers\n\n"))
  end

  test "accepts a post-deploy check after command evidence" do
    body = String.replace(@body, "\n## Next section", "\n- Post-deploy check: run the browser smoke on a physical Stream Deck.\n\n## Next section")

    assert {:ok, %{commands: [_, _]}} = LocalTestEvidence.parse(body)
  end

  test "rejects duplicate sections and fields" do
    assert {:error, "Duplicate Local tests sections"} = LocalTestEvidence.parse(@body <> @body)
    assert {:error, _reason} = LocalTestEvidence.parse(String.replace(@body, "Policy: partial", "Policy: partial\nPolicy: none"))
  end

  test "policy cannot understate repo mode and tested head must match when supplied" do
    assert {:ok, evidence} = LocalTestEvidence.parse(@body)
    assert :ok = LocalTestEvidence.validate(evidence, "partial", @head)
    assert :ok = LocalTestEvidence.validate(evidence, "none")
    assert {:error, "Local tests policy below repo mode all"} = LocalTestEvidence.validate(evidence, "all")
    assert {:error, "Local tests policy below repo mode partial"} = LocalTestEvidence.validate(%{evidence | policy: "none"}, "partial")
    assert {:error, "Local tests Tested head does not match PR head"} = LocalTestEvidence.validate(evidence, "partial", String.duplicate("c", 40))
    assert {:error, "Invalid repo local_tests mode"} = LocalTestEvidence.validate(evidence, "invalid")
  end
end
