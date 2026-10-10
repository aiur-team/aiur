defmodule AiurWeb.BuildOrder.PlanningSourceCase do
  @moduledoc false

  import ExUnit.Callbacks

  alias Aiur.BuildOrder.{Catalog, ProviderHealth, SelectedRoot}
  alias Aiur.{BuildOrdersCLI, RepoBase, TrackerIdentity}
  alias AiurWeb.BuildOrder.{PlanningSource, RouteState, TicketContextAdapter, TicketContextPresenter}

  @pack """
  {
    "build_order_id": "acme/widgets:demo",
    "title": "Demo Plan",
    "repository": "acme/widgets",
    "tickets": [
      {"id": "T-1", "title": "Foundation", "lane": "core", "phase": 1, "complexity": 3, "depends_on": [],
       "ticket": null, "doc": "tickets/T-1.md"},
      {"id": "T-2", "title": "Build on it", "lane": "web", "phase": 2, "complexity": 2, "depends_on": ["T-1"],
       "ticket": null, "doc": "tickets/T-2.md"}
    ]
  }
  """

  @canonical_pack """
  {
    "build_order_id": "acme/widgets:analytics-streamdeck",
    "title": "Analytics Stream Deck",
    "repository": "acme/widgets",
    "root_number": 9900,
    "tickets": [
      {"id": "AS-101", "title": "Wire stream", "lane": "runtime", "phase": 2,
       "complexity": 3, "ticket": 4101, "doc": "tickets/AS-101.md", "depends_on": []},
      {"id": "AS-102", "title": "Render deck", "lane": "dashboard-ui", "phase": 3,
       "complexity": 2, "ticket": 4102, "doc": "tickets/AS-102.md", "depends_on": ["AS-101"]}
    ]
  }
  """

  @mixed_pack """
  {
    "build_order_id": "acme/widgets:analytics-streamdeck",
    "title": "Analytics Stream Deck",
    "icon": "bolt",
    "repository": "acme/widgets",
    "root_number": 9900,
    "tickets": [
      {"id": "AS-101", "title": "Wire stream", "lane": "runtime", "phase": 1,
       "complexity": 3, "depends_on": [], "ticket": 4101, "doc": "tickets/AS-101.md"},
      {"id": "AS-102", "title": "Render deck", "lane": "dashboard-ui", "phase": 2,
       "complexity": 2, "depends_on": ["AS-101"], "ticket": null, "doc": "tickets/AS-102.md", "icon": "sparkles"}
    ]
  }
  """

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: false

      import AiurWeb.BuildOrder.PlanningSourceCase
      import ExUnit.CaptureLog
      import Phoenix.LiveViewTest

      alias Aiur.BuildOrder.{Catalog, ProviderHealth, SelectedRoot}
      alias Aiur.BuildOrder.GraphProjection.Snapshot
      alias Aiur.{BuildOrdersCLI, RepoBase, TrackerIdentity}
      alias Aiur.GitHub.Config
      alias AiurWeb.BuildOrder.{PlanningSource, RouteState, TicketContextAdapter, TicketContextPresenter}
      alias AiurWeb.BuildOrderPresenter
      alias AiurWeb.OperatorControlCenter.BuildOrderGridModel
      alias AiurWeb.OperatorControlCenter.BuildOrderSelected

      Module.put_attribute(__MODULE__, :pack, unquote(Macro.escape(@pack)))
      Module.put_attribute(__MODULE__, :canonical_pack, unquote(Macro.escape(@canonical_pack)))
      Module.put_attribute(__MODULE__, :mixed_pack, unquote(Macro.escape(@mixed_pack)))

      setup {AiurWeb.BuildOrder.PlanningSourceCase, :setup_case}
    end
  end

  def setup_case(_context) do
    path = Aiur.TestSupport.tmp_root!("planning-source-test") <> ".json"
    workspace_directory = Aiur.TestSupport.tmp_root!("planning-source-workspace")
    previous_workspace_directory = Application.get_env(:aiur, :build_order_workspace_directory)
    File.write!(path, @pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)
    Application.put_env(:aiur, :build_order_workspace_directory, workspace_directory)
    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn -> %{generation: 0, members: []} end)

    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn ->
      ProviderHealth.new(1, :healthy, true, observed_at: ~U[2026-08-02 12:00:00Z])
    end)

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_pack)
      Application.delete_env(:aiur, :build_order_planning_membership_snapshot)
      Application.delete_env(:aiur, :build_order_pack_status_health_snapshot)

      if previous_workspace_directory,
        do: Application.put_env(:aiur, :build_order_workspace_directory, previous_workspace_directory),
        else: Application.delete_env(:aiur, :build_order_workspace_directory)

      File.rm(path)
      File.rm_rf(workspace_directory)
    end)

    {:ok, workspace_directory: workspace_directory}
  end

  def put_membership(number, lifecycle) do
    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"number" => number, "node_id" => "I_live_#{number}"},
          {"acme", "widgets"},
          {"acme", "widgets"}
        )

      %{generation: 9, health: :healthy, freshness: %{status: :fresh}, members: [%{identity: identity, lifecycle: lifecycle}]}
    end)
  end
end
