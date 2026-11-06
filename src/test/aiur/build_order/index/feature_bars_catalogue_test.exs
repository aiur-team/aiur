defmodule Aiur.BuildOrder.Index.FeatureBarsCatalogueTest do
  @moduledoc """
  The Features row name for a feature whose tickets have all merged.

  A merged feature wears its label only on closed tickets, so neither the open-issue label
  observation nor a persisted history row necessarily describes it — the live dashboard fell
  through to the slug and showed "Mp E7". These cases drive the repository label catalogue
  through its real refresh and part read rather than a hand-built description map, so a
  regression in the source, the part wiring or the naming chain fails here.
  """
  use Aiur.TestSupport
  import Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.BuildOrder.Index.{FeatureBars, Parts}
  alias Aiur.GitHub.LabelCatalogue
  alias AiurWeb.Build.Index, as: WebIndex

  @owner "acme"
  @repo "widgets"
  @description "Feature collection: MP-E7 listener modes (steer, sync, async; Executor delivery)"

  setup do
    LabelCatalogue.reset()
    on_exit(&LabelCatalogue.reset/0)
    :ok
  end

  # The catalogue is filled by its own refresh over GitHub's label listing, not by a map
  # written into the test's parts.
  defp read_catalogue do
    assert :ok =
             LabelCatalogue.refresh(
               owner: @owner,
               repo: @repo,
               token: "test-token",
               base_url: "https://api.example.test",
               request_fun: fn request ->
                 send(self(), {:label_page, request.url})

                 {:ok,
                  %{
                    status: 200,
                    headers: [],
                    body: [%{"name" => "feature:mp-e7", "description" => @description, "color" => "5319e7"}]
                  }}
               end
             )

    assert_received {:label_page, _url}
    Parts.read(MapSet.new([:label_catalogue]), label_catalogue_fun: fn -> LabelCatalogue.fetch(@owner, @repo, 7_200_000) end)
  end

  # A merged ticket whose row carries no captured description: the shape the live history
  # store holds for a ticket that closed before descriptions were persisted.
  defp merged_row do
    row(1, %{
      labels: ["feature:mp-e7", "agent:ci-wait"],
      label_descriptions: %{},
      merged_at: DateTime.from_unix!(now(), :millisecond),
      pr_number: 9
    })
  end

  defp registry do
    feature = %{label: "MP-E7", hue: 175, epics: [%{key: "f-mp-e7", label: "Listener"}], from: now(), to: :none, baseline: :none}
    {:ok, %{features: %{"mp-e7" => feature}, owners: %{}, also: %{}, health: health()}}
  end

  # `Parts.read/2` answers the parts it read, so its result merges into the fixture.
  defp parts_with(read) do
    [merged_row()]
    |> parts()
    |> Map.put(:features, registry())
    |> Map.merge(read)
  end

  test "a registry label that is only a logical id takes the row name from the repository label catalogue" do
    parts = parts_with(read_catalogue())
    assert {:ok, index} = assemble(parts)

    assert [%{key: "mp-e7", label: "Listener modes", merged: 1, total: 1}] = index.feature_progress.bars
    assert [%{key: "mp-e7", label: "Listener modes", merged: 1, total: 1}] = FeatureBars.compute(parts, now())
  end

  test "without a recorded catalogue the same row falls back to the title-cased slug" do
    # The part read itself answers `:none` when no refresh has recorded a catalogue, which
    # is what a reverted fix looks like from here: the row has no description to show.
    parts = parts_with(Parts.read(MapSet.new([:label_catalogue]), []))

    assert [%{key: "mp-e7", label: "Mp E7", merged: 1, total: 1}] = FeatureBars.compute(parts, now())
  end

  test "the live label description outranks the description a history row captured" do
    stale = %{merged_row() | label_descriptions: %{"feature:mp-e7" => "Feature collection: MP-E7 older wording"}}
    parts = parts_with(read_catalogue()) |> Map.put(:history, {:ok, %{rows: %{1 => stale}, health: health()}})

    assert [%{key: "mp-e7", label: "Listener modes"}] = FeatureBars.compute(parts, now())
  end

  test "the dashboard's all-parts read covers every part the build index declares" do
    declared = MapSet.new(Parts.keys())
    read_by_dashboard = MapSet.new(WebIndex.read_parts())

    assert MapSet.subset?(declared, read_by_dashboard),
           "build index declares #{inspect(MapSet.difference(declared, read_by_dashboard) |> MapSet.to_list())} but the dashboard never reads it"
  end
end
