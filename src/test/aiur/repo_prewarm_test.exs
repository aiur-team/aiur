defmodule Aiur.RepoPrewarmTest do
  use ExUnit.Case, async: true

  test "dogfood prewarm builds the dialyzer PLT" do
    repo_root = Path.expand("..", File.cwd!())
    prewarm = File.read!(Path.join([repo_root, ".aiur", "prewarm"]))

    assert prewarm =~ "mise exec -- mix compile && mise exec -- mix dialyzer --plt"
  end
end
