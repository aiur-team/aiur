defmodule Aiur.Experiments.RepoPathTest do
  use ExUnit.Case, async: false

  test "experiments share the repo state node" do
    assert Aiur.RepoBase.experiments_path("aiur-team/aiur") == Path.join(Aiur.RepoBase.repo_path("aiur-team/aiur"), "experiments")
  end
end
