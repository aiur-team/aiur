defmodule Aiur.BuildOrder.PackStatusTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{PackPaths, PackStatus}
  alias AiurWeb.BuildOrder.PlanningSource
  alias AiurWeb.BuildOrderPresenter
  alias AiurWeb.OperatorControlCenter.BuildOrderGridModel

  @pack """
  {
    "build_order_id": "acme/widgets:analytics-streamdeck",
    "title": "Analytics Stream Deck",
    "repository": "acme/widgets",
    "root_number": 9900,
    "tickets": [
      {"id": "AS-101", "title": "Wire stream", "lane": "runtime", "phase": 1,
       "complexity": 2, "depends_on": [], "ticket": 4101, "doc": "tickets/AS-101.md"},
      {"id": "AS-102", "title": "Render deck", "lane": "runtime", "phase": 1,
       "complexity": 2, "depends_on": [], "ticket": 4102, "doc": "tickets/AS-102.md"},
      {"id": "AS-103", "title": "Drop key", "lane": "runtime", "phase": 1,
       "complexity": 2, "depends_on": [], "ticket": 4103, "doc": "tickets/AS-103.md"},
      {"id": "AS-104", "title": "Draft only", "lane": "runtime", "phase": 2,
       "complexity": 2, "depends_on": [], "ticket": null, "doc": "tickets/AS-104.md"}
    ]
  }
  """

  setup do
    directory = Path.join(System.tmp_dir!(), "pack-status-#{System.unique_integer([:positive])}")
    pack_path = Path.join([directory, "analytics-streamdeck", "build-order.json"])

    File.mkdir_p!(Path.dirname(pack_path))
    File.write!(pack_path, @pack)

    on_exit(fn -> File.rm_rf(directory) end)

    {:ok, pack_path: pack_path, status_path: PackPaths.status_path(pack_path)}
  end

  defp start_poller(pack_path, request_fun) do
    start_supervised!(
      {PackStatus,
       name: nil,
       poll_on_start: false,
       paths_fun: fn -> [pack_path] end,
       repo_fun: fn -> {:ok, {"acme", "widgets"}} end,
       token_fun: fn -> {:ok, "token"} end,
       request_fun: request_fun,
       now_fun: fn -> ~U[2026-08-02 12:00:00Z] end}
    )
  end

  defp issues_response(issues) do
    test = self()

    fn %{method: :post, body: %{"query" => query}} ->
      send(test, {:query, query})
      {:ok, %{status: 200, body: %{"data" => %{"repository" => issues}}}}
    end
  end

  test "writes tracker completion for promoted members into status.json", context do
    poller =
      start_poller(
        context.pack_path,
        issues_response(%{
          "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"},
          "i4102" => %{"number" => 4102, "state" => "CLOSED", "stateReason" => "NOT_PLANNED"},
          "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
        })
      )

    assert {:ok, [written]} = PackStatus.refresh_sync(poller)
    assert written == context.pack_path

    # Drafts have no tracker fact and must not be invented.
    assert_receive {:query, query}
    assert query =~ "i4101: issue(number: 4101)"
    refute query =~ "4104"

    assert %{"members" => members} = Jason.decode!(File.read!(context.status_path))
    assert %{"lifecycle" => "completed", "observed_at" => "2026-08-02T12:00:00Z"} = members["4101"]
    assert %{"lifecycle" => "cancelled"} = members["4102"]
    assert %{"lifecycle" => "open"} = members["4103"]
    refute Map.has_key?(members, "4104")
  end

  test "a merged member renders 100% on the Build Order page after reconcile", context do
    previous_pack = Application.get_env(:aiur, :build_order_planning_pack)
    previous_membership = Application.get_env(:aiur, :build_order_planning_membership_snapshot)

    Application.put_env(:aiur, :build_order_planning_pack, context.pack_path)
    # No live membership at all: this is the second run of a Build Order whose
    # members merged during an earlier run.
    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn -> %{generation: 0, members: []} end)

    on_exit(fn ->
      if previous_pack,
        do: Application.put_env(:aiur, :build_order_planning_pack, previous_pack),
        else: Application.delete_env(:aiur, :build_order_planning_pack)

      if previous_membership,
        do: Application.put_env(:aiur, :build_order_planning_membership_snapshot, previous_membership),
        else: Application.delete_env(:aiur, :build_order_planning_membership_snapshot)
    end)

    # Before the projection exists every merged member reads as 0%.
    assert overall_percent() == 0

    poller =
      start_poller(
        context.pack_path,
        issues_response(%{
          "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"},
          "i4102" => %{"number" => 4102, "state" => "CLOSED", "stateReason" => "COMPLETED"},
          "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
        })
      )

    assert {:ok, [_written]} = PackStatus.refresh_sync(poller)

    grid = grid()
    assert grid.overall_pct > 0
    assert Enum.find(grid.cards, &(&1.id == "4101")).state == :merged
    assert Enum.find(grid.cards, &(&1.id == "4101")).progress == 100
    assert Enum.find(grid.cards, &(&1.id == "4103")).state != :merged
  end

  test "preserves unrelated status keys and earlier members", context do
    File.write!(context.status_path, ~s({"state":"active","members":{"4102":"completed"}}))

    poller =
      start_poller(
        context.pack_path,
        issues_response(%{"i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"}})
      )

    assert {:ok, [_written]} = PackStatus.refresh_sync(poller)

    status = Jason.decode!(File.read!(context.status_path))
    assert status["state"] == "active"
    assert status["members"]["4102"] == "completed"
    assert %{"lifecycle" => "completed"} = status["members"]["4101"]
  end

  test "does not rewrite an unchanged projection", context do
    poller =
      start_poller(
        context.pack_path,
        issues_response(%{"i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"}})
      )

    assert {:ok, [_written]} = PackStatus.refresh_sync(poller)
    written_at = File.stat!(context.status_path).mtime
    body = File.read!(context.status_path)

    assert {:ok, [_written]} = PackStatus.refresh_sync(poller)
    assert File.stat!(context.status_path).mtime == written_at
    assert File.read!(context.status_path) == body
  end

  test "a failed tracker read leaves the previous projection intact", context do
    File.write!(context.status_path, ~s({"members":{"4101":"completed"}}))

    poller =
      start_poller(context.pack_path, fn _request ->
        {:ok, %{status: 502, body: %{}}}
      end)

    assert {:ok, []} = PackStatus.refresh_sync(poller)
    assert Jason.decode!(File.read!(context.status_path)) == %{"members" => %{"4101" => "completed"}}
  end

  test "reports unavailable without a token rather than clearing status", context do
    poller =
      start_supervised!(
        {PackStatus,
         name: nil,
         poll_on_start: false,
         paths_fun: fn -> [context.pack_path] end,
         repo_fun: fn -> {:ok, {"acme", "widgets"}} end,
         token_fun: fn -> {:error, :missing_token} end,
         request_fun: fn _request -> flunk("must not reach GitHub without a token") end}
      )

    assert {:error, :missing_token} = PackStatus.refresh_sync(poller)
    refute File.exists?(context.status_path)
  end

  defp grid do
    [root] = PlanningSource.catalog().data.entries
    {:ok, snapshot} = PlanningSource.demand(root.identity)

    snapshot
    |> BuildOrderPresenter.present(:unavailable, :unavailable)
    |> BuildOrderGridModel.build(nil)
  end

  defp overall_percent, do: grid().overall_pct
end
