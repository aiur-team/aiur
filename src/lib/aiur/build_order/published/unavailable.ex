defmodule Aiur.BuildOrder.Published.Unavailable do
  @moduledoc """
  The `build-order.v1` document for a projection with no readable data.

  It publishes `status: "unknown"` with a reason on every source, on the
  progress roll and on the critical path, and no tickets. A reader must show
  this as an unavailable reading, never as an empty Build Order.
  """

  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.Published.{Document, Graph, Progress, Sources}

  @spec document(Snapshot.t(), DateTime.t()) :: map()
  def document(%Snapshot{} = snapshot, now) do
    tracker = Sources.tracker(snapshot.health)
    reason = Sources.reason(snapshot.health)
    {root_id, root_title} = unavailable_root(snapshot)

    Document.document(
      %{
        build_order_id: unavailable_id(snapshot, root_id),
        title: root_title,
        repository: Document.repository(snapshot, Document.identity(snapshot)),
        root: %{
          "id" => root_id,
          "title" => root_title,
          "number" => Document.number_or_nil(root_id),
          "url" => nil,
          "epic" => nil,
          "plan_version" => nil,
          "researched_at_commit" => nil
        },
        now: now
      },
      %{
        "pack" => Sources.pack(%{}, "pack_not_loaded"),
        "tracker" => tracker,
        "progress" => Sources.progress(tracker, reason)
      },
      %{
        epics: [],
        features: [],
        lanes: [],
        tickets: [],
        edges: [],
        gates: [],
        waves: [],
        critical_path: Graph.critical_path([], [], [], available?: false, reason: reason),
        progress: Progress.unknown(reason)
      }
    )
  end

  defp unavailable_root(%Snapshot{scope: {:selected, identity}}) do
    case Document.identifier(identity) do
      nil -> {"unknown", "Build Order unavailable"}
      number -> {number, "Build Order " <> number}
    end
  end

  defp unavailable_root(_snapshot), do: {"catalog", "Build Order catalog"}

  defp unavailable_id(snapshot, root_id) do
    case Document.repository(snapshot, Document.identity(snapshot)) do
      nil -> "unknown:build-order-" <> root_id
      repository -> repository <> ":build-order-" <> root_id
    end
  end
end
