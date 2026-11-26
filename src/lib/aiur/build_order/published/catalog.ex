defmodule Aiur.BuildOrder.Published.Catalog do
  @moduledoc """
  The catalog `build-order.v1` document.

  A catalog projection publishes one epic per imported root until epic records
  above features land (#7496). It carries no edges, gates or lanes: the catalog
  is a list of roots, not a graph, and claiming otherwise would invent structure
  the projection does not hold.
  """

  alias Aiur.BuildOrder.{Catalog, RootSummary}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.Published.{Document, Progress, Sources}
  alias Aiur.TrackerIdentity

  @spec document(Snapshot.t(), Catalog.t(), DateTime.t(), keyword()) :: map()
  def document(snapshot, %Catalog{} = catalog, now, _opts) do
    health = catalog.provider || snapshot.health
    tracker = Sources.tracker(health)
    available? = Sources.available?(health)
    reason = Sources.reason(health)
    counts_reason = count_failure(catalog)

    rows =
      catalog.entries
      |> Enum.filter(&match?(%RootSummary{}, &1))
      |> Enum.map(&catalog_row/1)
      |> Enum.sort_by(& &1.key)

    facts = Enum.map(rows, &catalog_ticket(&1, available?))
    progress_opts = Document.progress_opts(available?, reason, tracker)

    doc = %{
      build_order_id: catalog_id(snapshot),
      title: "Build Order catalog",
      repository: Document.repository(snapshot, nil),
      root: %{
        "id" => "catalog",
        "title" => "Build Order catalog",
        "number" => nil,
        "url" => nil,
        "epic" => nil,
        "plan_version" => nil,
        "researched_at_commit" => nil
      },
      now: now
    }

    Document.document(
      doc,
      %{
        "pack" => Sources.catalog_pack(),
        "tracker" => tracker,
        "progress" => Sources.progress(tracker, counts_reason)
      },
      %{
        epics: Enum.map(rows, &catalog_group(&1, facts, "epic", progress_opts)),
        features: Enum.map(rows, &catalog_group(&1, facts, "feature", progress_opts)),
        lanes: [],
        tickets: facts,
        edges: [],
        gates: [],
        waves: catalog_waves(facts),
        critical_path: catalog_critical_path(available?, reason),
        progress: Progress.aggregate(facts, progress_opts)
      }
    )
  end

  defp catalog_row(%RootSummary{} = entry) do
    key = identity_locator(entry.identity) || "root-#{:erlang.phash2(entry.title)}"
    %{entry: entry, key: key, feature: "root:" <> key}
  end

  defp catalog_ticket(row, available?) do
    %{
      "id" => row.key,
      "number" => identity_number(row.entry.identity),
      "title" => row.entry.title,
      "url" => row.entry.url,
      "kind" => "umbrella",
      "provenance" => "planned",
      "epic" => row.key,
      "feature" => row.feature,
      "lane" => nil,
      "phase" => nil,
      "wave" => 1,
      "complexity" => nil,
      "points" => nil,
      "estimate_hours" => nil,
      "status" => if(available?, do: Document.lifecycle_status(row.entry.lifecycle), else: "unknown"),
      "progress_percent" => catalog_percent(row.entry),
      "started_at" => nil,
      "ended_at" => nil
    }
  end

  defp catalog_group(row, facts, "epic", opts) do
    %{
      "key" => row.key,
      "title" => row.entry.title,
      "label" => nil,
      "url" => row.entry.url,
      "icon" => row.entry.icon,
      "hue" => nil,
      "features" => [row.feature],
      "progress" => Progress.aggregate(Enum.filter(facts, &(&1["epic"] == row.key)), opts)
    }
  end

  defp catalog_group(row, facts, "feature", opts) do
    %{
      "key" => row.feature,
      "title" => row.entry.title,
      "label" => nil,
      "epic" => row.key,
      "icon" => row.entry.icon,
      "hue" => nil,
      "url" => row.entry.url,
      "progress" => Progress.aggregate(Enum.filter(facts, &(&1["feature"] == row.feature)), opts)
    }
  end

  defp catalog_waves([]), do: []

  defp catalog_waves(facts),
    do: [%{"index" => 1, "tickets" => Enum.map(facts, & &1["id"]), "starts_at" => nil, "ends_at" => nil}]

  defp catalog_critical_path(available?, reason) do
    %{
      "status" => if(available?, do: "known", else: "unknown"),
      "tickets" => [],
      "hours" => if(available?, do: 0, else: nil),
      "reason" => reason
    }
  end

  defp catalog_percent(%RootSummary{progress: progress, progress_resolution: resolution})
       when is_integer(progress) and resolution in [:resolved, :partial],
       do: progress

  defp catalog_percent(_entry), do: nil

  defp count_failure(%Catalog{count_resolution_failure: nil}), do: nil
  defp count_failure(%Catalog{count_resolution_failure: failure}), do: Atom.to_string(failure)

  defp catalog_id(%Snapshot{repository: {owner, repository}}),
    do: to_string(owner) <> "/" <> to_string(repository) <> ":catalog"

  defp catalog_id(_snapshot), do: "unknown:catalog"

  defp identity_locator(%TrackerIdentity{owner: owner, repository: name, identifier: identifier})
       when is_binary(owner) and is_binary(name) and is_binary(identifier),
       do: owner <> "/" <> name <> "#" <> identifier

  defp identity_locator(_identity), do: nil

  defp identity_number(%TrackerIdentity{identifier: identifier}), do: Document.number_or_nil(identifier)
  defp identity_number(_identity), do: nil
end
