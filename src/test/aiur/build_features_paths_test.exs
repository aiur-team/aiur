defmodule Aiur.BuildFeaturesPathsTest do
  use ExUnit.Case, async: false
  alias Aiur.Config.Paths

  test "build_features_state_dir honours override and otherwise nests under decision state" do
    original = Application.get_env(:aiur, :build_features_state_dir)

    on_exit(fn ->
      if is_nil(original), do: Application.delete_env(:aiur, :build_features_state_dir), else: Application.put_env(:aiur, :build_features_state_dir, original)
    end)

    root = Aiur.TestSupport.tmp_root!("features-path")
    on_exit(fn -> File.rm_rf!(root) end)
    Application.put_env(:aiur, :build_features_state_dir, root)
    assert Paths.build_features_state_dir() == {:ok, root}
    Application.delete_env(:aiur, :build_features_state_dir)
    {:ok, decisions} = Paths.decision_state_dir()
    assert Paths.build_features_state_dir() == {:ok, Path.join(decisions, "build-features")}
  end
end
