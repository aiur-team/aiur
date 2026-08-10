defmodule Aiur.BuildOrder.ProgressRendererTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.{ProgressRenderer, RootSummary}

  @resolved RootSummary.new(%{
              progress: 42,
              progress_resolution: :resolved,
              progress_resolved_count: 5,
              member_count: 5
            })
  @partial RootSummary.new(%{
             progress: 40,
             progress_resolution: :partial,
             progress_resolved_count: 2,
             member_count: 5
           })
  @unresolved RootSummary.new(%{
                progress_resolution: :unresolved,
                progress_resolved_count: 0,
                member_count: 5
              })
  @unknown RootSummary.new(%{progress: 91, member_count: 5})

  describe "terminal/1" do
    test "renders all four states distinctly" do
      rendered = Enum.map([@resolved, @partial, @unresolved, @unknown], &ProgressRenderer.terminal/1)

      assert rendered == ["42%", "40% partial (2/5 resolved)", "unresolved", "unknown"]
      assert length(Enum.uniq(rendered)) == 4
    end

    test "fails malformed or missing contracts closed to unknown" do
      assert ProgressRenderer.terminal(%{progress: 73, progress_resolution: :unexpected}) == "unknown"
      assert ProgressRenderer.terminal(%{progress: 73}) == "unknown"
      assert ProgressRenderer.terminal(nil) == "unknown"
    end

    test "accepts the string-keyed JSON projection without reparsing its label" do
      assert ProgressRenderer.terminal(%{
               "progress" => 40,
               "progress_resolution" => "partial",
               "progress_resolved_count" => 2,
               "member_count" => 5
             }) == "40% partial (2/5 resolved)"
    end
  end

  describe "json/1" do
    test "carries resolution and resolved count for all four states" do
      assert ProgressRenderer.json(@resolved) == %{
               "progress" => 42,
               "progress_resolution" => "resolved",
               "progress_resolved_count" => 5
             }

      assert ProgressRenderer.json(@partial) == %{
               "progress" => 40,
               "progress_resolution" => "partial",
               "progress_resolved_count" => 2
             }

      assert ProgressRenderer.json(@unresolved) == %{
               "progress" => nil,
               "progress_resolution" => "unresolved",
               "progress_resolved_count" => 0
             }

      assert ProgressRenderer.json(@unknown) == %{
               "progress" => nil,
               "progress_resolution" => "unknown",
               "progress_resolved_count" => nil
             }
    end

    test "fails malformed string-keyed input closed to unknown" do
      assert ProgressRenderer.json(%{"progress" => 73, "progress_resolution" => "surprise"}) == %{
               "progress" => nil,
               "progress_resolution" => "unknown",
               "progress_resolved_count" => nil
             }
    end
  end

  describe "html/1" do
    test "projects all four states into unambiguous HTML labels" do
      resolved = ProgressRenderer.html(@resolved)
      partial = ProgressRenderer.html(@partial)
      unresolved = ProgressRenderer.html(@unresolved)
      unknown = ProgressRenderer.html(@unknown)

      assert %{state: :resolved, label: "42%", percent: 42, coverage: nil} = resolved
      assert %{state: :partial, label: "40% partial", percent: 40, coverage: "2/5 resolved"} = partial
      assert %{state: :unresolved, label: "unresolved", percent: nil, coverage: nil} = unresolved
      assert %{state: :unknown, label: "unknown", percent: nil, coverage: nil} = unknown

      assert length(Enum.uniq(Enum.map([resolved, partial, unresolved, unknown], & &1.label))) == 4
      assert partial.aria_label =~ "partial"
      assert unresolved.aria_label =~ "could not be resolved"
      refute unknown.aria_label =~ "unresolved"
      refute unknown.aria_label =~ "failed"
    end

    test "fails an internally inconsistent resolved value closed to unknown" do
      assert %{state: :unknown, label: "unknown", percent: nil} =
               ProgressRenderer.html(%RootSummary{progress_resolution: :resolved, progress: nil})
    end

    test "keeps partial presentation explicit when count coverage is unavailable" do
      partial = ProgressRenderer.html(%{progress: 40, progress_resolution: :partial})

      assert %{state: :partial, label: "40% partial", percent: 40, coverage: nil} = partial
      assert partial.aria_label =~ "coverage unavailable"
      assert partial.title =~ "coverage is unavailable"
    end
  end

  describe "semantic count consistency" do
    test "fails contradictory declared resolution counts closed for every medium" do
      contradictions = [
        %{progress: 50, progress_resolution: :resolved, progress_resolved_count: 2, member_count: 3},
        %{progress: 50, progress_resolution: :partial, progress_resolved_count: 0, member_count: 3},
        %{progress: 50, progress_resolution: :partial, progress_resolved_count: 3, member_count: 3},
        %{progress_resolution: :unresolved, progress_resolved_count: 1, member_count: 3}
      ]

      Enum.each(contradictions, fn value ->
        assert ProgressRenderer.terminal(value) == "unknown"

        assert ProgressRenderer.json(value) == %{
                 "progress" => nil,
                 "progress_resolution" => "unknown",
                 "progress_resolved_count" => nil
               }

        assert %{state: :unknown, label: "unknown", percent: nil} = ProgressRenderer.html(value)
      end)
    end

    test "accepts settled state semantics when counts are absent or consistent" do
      assert ProgressRenderer.terminal(%{progress: 50, progress_resolution: :resolved}) == "50%"
      assert ProgressRenderer.terminal(%{progress: 50, progress_resolution: :partial}) == "50% partial"
      assert ProgressRenderer.terminal(%{progress_resolution: :unresolved}) == "unresolved"
    end
  end
end
