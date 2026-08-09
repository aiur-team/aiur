defmodule Aiur.BuildOrder.RootSummaryProgressTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.RootSummary

  describe "progress resolution" do
    test "a source that resolved every member reports a percent it stands behind" do
      root = RootSummary.new(%{progress: 42, progress_resolution: :resolved, progress_resolved_count: 35})

      assert root.progress == 42
      assert root.progress_resolution == :resolved
      assert root.progress_resolved_count == 35
    end

    test "an empty pack is a resolved zero, not an unknown" do
      root = RootSummary.new(%{progress: 0, progress_resolution: :resolved, progress_resolved_count: 0})

      assert root.progress == 0
      assert root.progress_resolution == :resolved
    end

    test "an unresolved pack never carries a percent, even if one is supplied" do
      root = RootSummary.new(%{progress: 0, progress_resolution: :unresolved})

      assert is_nil(root.progress)
      assert root.progress_resolution == :unresolved
    end

    # The defect class this guards: a claimed resolution with an unusable
    # percent must degrade into the state that says "unknown", never into the
    # blank that is indistinguishable from "this provider reports nothing".
    test "a claimed resolution with no usable percent fails closed to unresolved" do
      for claimed <- [:resolved, :partial], value <- [nil, "40", 140, -1] do
        root = RootSummary.new(%{progress: value, progress_resolution: claimed})

        assert is_nil(root.progress)
        assert root.progress_resolution == :unresolved
      end
    end

    test "a source that makes no resolution claim keeps the legacy unknown shape" do
      assert RootSummary.new(%{progress: 42}).progress_resolution == :unknown
      assert RootSummary.new(%{}).progress_resolution == :unknown
      assert is_nil(RootSummary.new(%{}).progress)
    end

    test "resolved_count is bounded like every other count" do
      assert RootSummary.new(%{progress_resolved_count: -1}).progress_resolved_count == nil
      assert RootSummary.new(%{progress_resolved_count: "3"}).progress_resolved_count == nil
    end
  end
end
