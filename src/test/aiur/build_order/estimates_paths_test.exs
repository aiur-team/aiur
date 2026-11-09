defmodule Aiur.BuildOrder.EstimatesPathsTest do
  use ExUnit.Case, async: false
  alias Aiur.Config.Paths

  test "estimate path honors its override and otherwise owns a separate decision-state leaf" do
    dir = Aiur.TestSupport.tmp_root!("estimate-path")
    old = for key <- [:build_estimates_state_dir, :decision_state_dir], into: %{}, do: {key, Application.fetch_env(:aiur, key)}

    on_exit(fn ->
      for {key, value} <- old do
        case value do
          {:ok, v} -> Application.put_env(:aiur, key, v)
          :error -> Application.delete_env(:aiur, key)
        end
      end

      Aiur.TestCleanup.rm_rf!(dir)
    end)

    Application.delete_env(:aiur, :build_estimates_state_dir)
    Application.put_env(:aiur, :decision_state_dir, dir)
    assert Paths.build_estimates_state_dir() == {:ok, Path.join(dir, "build-estimates")}
    specific = Path.join(dir, "explicit")
    Application.put_env(:aiur, :build_estimates_state_dir, specific)
    assert Paths.build_estimates_state_dir() == {:ok, specific}
  end
end
