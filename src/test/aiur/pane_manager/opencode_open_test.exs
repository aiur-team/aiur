defmodule Aiur.PaneManager.OpencodeOpenTest do
  use ExUnit.Case, async: true

  describe "module public API" do
    test "do_open, open_opencode_pane, and move_warm_pane_visible are exported" do
      exports = Aiur.PaneManager.OpencodeOpen.__info__(:functions)
      assert {:do_open, 5} in exports
      assert {:open_opencode_pane, 4} in exports
      assert {:move_warm_pane_visible, 5} in exports
    end
  end
end
