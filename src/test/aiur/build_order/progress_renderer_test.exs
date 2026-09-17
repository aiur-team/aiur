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
  @empty RootSummary.new(%{
           progress: 0,
           progress_resolution: :resolved,
           progress_resolved_count: 0,
           member_count: 0
         })

  describe "terminal/1" do
    test "renders all five states distinctly" do
      rendered = Enum.map([@resolved, @partial, @empty, @unresolved, @unknown], &ProgressRenderer.terminal/1)

      assert rendered == ["42%", "40% partial (2/5 resolved)", "empty", "unresolved", "unknown"]
      assert length(Enum.uniq(rendered)) == 5
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

      assert ProgressRenderer.json(@empty) == %{
               "progress" => nil,
               "progress_resolution" => "empty",
               "progress_resolved_count" => 0
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

  describe "last-known readings" do
    @stale_at ~U[2026-09-16 20:00:00Z]
    @now ~U[2026-09-16 20:12:30Z]
    @stale_one %{progress: 80, progress_resolution: :resolved, progress_resolved_count: 1, member_count: 1, stale_count: 1, stale_observed_at: @stale_at}
    @stale_many %{progress: 66, progress_resolution: :resolved, progress_resolved_count: 3, member_count: 3, stale_count: 2, stale_observed_at: @stale_at}
    @live %{progress: 80, progress_resolution: :resolved, progress_resolved_count: 1, member_count: 1, stale_count: 0, stale_observed_at: nil}

    test "terminal keeps the percent and appends the last-known count and age" do
      assert ProgressRenderer.terminal(@stale_one, now: @now) == "80% (last known 12m ago)"
      assert ProgressRenderer.terminal(@stale_many, now: @now) == "66% (2 last known, oldest 12m ago)"
      assert ProgressRenderer.terminal(@live, now: @now) == "80%"
      assert ProgressRenderer.terminal(%{@stale_one | stale_observed_at: nil}, now: @now) == "80% (last known age unknown)"
    end

    test "json publishes the count and oldest reading only when the value carries stale evidence" do
      assert ProgressRenderer.json(@stale_one) == %{
               "progress" => 80,
               "progress_resolution" => "resolved",
               "progress_resolved_count" => 1,
               "progress_stale_count" => 1,
               "progress_stale_observed_at" => "2026-09-16T20:00:00Z"
             }

      assert ProgressRenderer.json(@live) == %{
               "progress" => 80,
               "progress_resolution" => "resolved",
               "progress_resolved_count" => 1,
               "progress_stale_count" => 0,
               "progress_stale_observed_at" => nil
             }

      refute Map.has_key?(ProgressRenderer.json(@resolved), "progress_stale_count")
    end

    test "terminal reads the JSON spelling back so the CLI's human output matches its JSON" do
      assert @stale_one |> ProgressRenderer.json() |> Map.put("member_count", 1) |> ProgressRenderer.terminal(now: @now) == "80% (last known 12m ago)"
    end

    test "html tags the projection last known with a note, aria label, and title" do
      projection = ProgressRenderer.html(@stale_one, now: @now)

      assert projection.label == "80%"
      assert projection.percent == 80
      assert projection.freshness == :last_known
      assert projection.note == "last known 12m ago"
      assert projection.aria_label == "80% complete; completion fully resolved; last known 12m ago"
      assert projection.title =~ "One member counts the progress last observed 12m ago; no newer progress reading has been observed."
      assert ProgressRenderer.html(@stale_many, now: @now).title =~ "2 members count the progress last observed for each (oldest 12m ago)"
      refute projection.title =~ "agent"

      assert %{freshness: :current, note: nil} = ProgressRenderer.html(@live, now: @now)
      assert %{freshness: :current, note: nil} = ProgressRenderer.html(@resolved, now: @now)
    end

    test "a last-known marker never qualifies a projection that shows no percent" do
      unresolved = %{progress: nil, progress_resolution: :unresolved, progress_resolved_count: 0, member_count: 2, stale_count: 1, stale_observed_at: @stale_at}

      assert ProgressRenderer.terminal(unresolved, now: @now) == "unresolved"
      assert %{freshness: :current, note: nil} = ProgressRenderer.html(unresolved, now: @now)
    end

    test "ages are relative to the caller's clock" do
      assert ProgressRenderer.terminal(@stale_one, now: DateTime.add(@stale_at, 30, :second)) == "80% (last known just now)"
      assert ProgressRenderer.terminal(@stale_one, now: DateTime.add(@stale_at, 2 * 3_600, :second)) == "80% (last known 2h ago)"
      assert ProgressRenderer.terminal(@stale_one, now: DateTime.add(@stale_at, 3 * 86_400, :second)) == "80% (last known 3d ago)"
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

    test "projects a resolved zero-member Build Order as empty instead of unstarted" do
      assert %{
               state: :empty,
               label: "Empty",
               percent: nil,
               coverage: nil,
               aria_label: "Empty Build Order; no members",
               title: "This Build Order has no members."
             } = ProgressRenderer.html(@empty)
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
