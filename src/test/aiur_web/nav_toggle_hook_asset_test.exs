defmodule AiurWeb.NavToggleHookAssetTest do
  use ExUnit.Case, async: true

  test "serves the shared navigation hook with reconnect handling" do
    assert {:ok, "application/javascript", hook} = AiurWeb.StaticAssets.fetch("/nav-toggle-hook.js")
    assert hook =~ "window.AiurNavToggleHook"
    assert hook =~ "reconnected: function () { this.pending = undefined; this.mirror(); }"
    assert hook =~ "this.pending = collapsed;"
    assert hook =~ "import(\"/aiur-style/js/storage.js\")"
  end
end
