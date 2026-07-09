defmodule Aiur.Workspace.RemoteTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.Remote

  test "remote_shell_assign emits escaped assignment and tilde expansion cases" do
    script = Remote.remote_shell_assign("workspace", "~/can't")

    assert script =~ "workspace='~/can'\"'\"'t'"
    assert script =~ "  '~') workspace=\"$HOME\" ;;"
    assert script =~ "  '~/'*) workspace=\"$HOME/${workspace#~/}\" ;;"
  end
end
