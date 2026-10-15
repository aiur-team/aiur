defmodule Aiur.Experiments.RepoPathTest do
  use ExUnit.Case, async: false
  alias Aiur.Experiments.Paths

  test "capture is reserved for the journal and cannot be an experiment id" do
    refute Paths.valid_id?("capture")
    assert_raise ArgumentError, fn -> Paths.experiment("capture") end
  end

  test "experiments share the repo state node" do
    assert Aiur.RepoBase.experiments_path("aiur-team/aiur") == Path.join(Aiur.RepoBase.repo_path("aiur-team/aiur"), "experiments")
  end
end
