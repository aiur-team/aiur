defmodule Aiur.Opencode.PersistentPaneTest do
  use ExUnit.Case, async: true

  alias Aiur.Opencode.PersistentPane

  test "new/3 defaults to :pending with no pane id" do
    pane = PersistentPane.new("issue-42", "ses_abc")
    assert pane.identifier == "issue-42"
    assert pane.session_id == "ses_abc"
    assert pane.pane_id == nil
    assert pane.status == :pending
    assert pane.attached_at == nil
  end

  test "new/3 accepts pane_id and status overrides" do
    pane = PersistentPane.new("issue-42", "ses_abc", pane_id: "%5", status: :hidden)
    assert pane.pane_id == "%5"
    assert pane.status == :hidden
  end

  test "with_pane_id/2 sets the pane id and seeds attached_at" do
    pane = PersistentPane.new("issue-42", "ses_abc")
    updated = PersistentPane.with_pane_id(pane, "%9")
    assert updated.pane_id == "%9"
    assert is_integer(updated.attached_at)
  end

  test "with_pane_id/2 does not overwrite an existing attached_at" do
    original = PersistentPane.new("issue-42", "ses_abc", pane_id: "%9")
    seeded = PersistentPane.with_pane_id(original, "%9")
    re_seeded = PersistentPane.with_pane_id(seeded, "%9")
    assert seeded.attached_at == re_seeded.attached_at
  end

  test "with_status/2 transitions valid statuses" do
    pane = PersistentPane.new("issue-42", "ses_abc")

    for status <- [:pending, :attaching, :hidden, :visible] do
      assert %PersistentPane{status: ^status} = PersistentPane.with_status(pane, status)
    end
  end

  test "with_status/2 rejects unknown statuses via guard" do
    pane = PersistentPane.new("issue-42", "ses_abc")
    assert_raise FunctionClauseError, fn -> PersistentPane.with_status(pane, :exploded) end
  end
end
