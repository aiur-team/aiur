defmodule Aiur.TestResetQueueTest do
  use ExUnit.Case, async: true

  alias Aiur.TestReset

  test "reset removes the queued marker before restoring agent:todo" do
    [remove_argv, add_argv] = TestReset.reset_labels_command_args(101)
    assert ["issue", "edit", "101", "--remove-label", labels] = remove_argv
    assert "agent:queued" in String.split(labels, ",")
    assert add_argv == ["issue", "edit", "101", "--add-label", "agent:todo"]
  end
end
