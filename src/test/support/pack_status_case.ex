defmodule Aiur.BuildOrder.PackStatusCase do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Aiur.BuildOrder.{PackPaths, PackStatus, ProviderHealth}
  alias AiurWeb.BuildOrder.{PackOverlay, PlanningSource, RouteState}
  alias AiurWeb.BuildOrderPresenter
  alias AiurWeb.OperatorControlCenter.BuildOrderGridModel

  # Async refresh completion crosses the task, poller mailbox, and PubSub.
  @async_assert_timeout 2_000

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

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: false

      import Aiur.BuildOrder.PackStatusCase

      alias Aiur.BuildOrder.{PackPaths, PackStatus, ProviderHealth}
      alias Aiur.GitHub.Config
      alias Aiur.RepoBase
      alias AiurWeb.BuildOrder.{PackOverlay, PlanningSource, RouteState}
      alias AiurWeb.BuildOrderPresenter
      alias AiurWeb.OperatorControlCenter.BuildOrderGridModel

      Module.put_attribute(__MODULE__, :async_assert_timeout, unquote(Macro.escape(@async_assert_timeout)))
      Module.put_attribute(__MODULE__, :pack, unquote(Macro.escape(@pack)))

      setup {Aiur.BuildOrder.PackStatusCase, :setup_case}
    end
  end

  def setup_case(_context) do
    directory = Aiur.TestSupport.tmp_root!("pack-status")
    pack_path = Path.join([directory, "analytics-streamdeck", "build-order.json"])
    workspace_directory = Path.join(directory, "workspace-build-orders")
    previous_workspace_directory = Application.get_env(:aiur, :build_order_workspace_directory)

    File.mkdir_p!(Path.dirname(pack_path))
    File.write!(pack_path, @pack)
    Application.put_env(:aiur, :build_order_workspace_directory, workspace_directory)

    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn ->
      ProviderHealth.new(1, :healthy, true, observed_at: ~U[2026-08-02 12:00:00Z])
    end)

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_pack_status_health_snapshot)

      if previous_workspace_directory,
        do: Application.put_env(:aiur, :build_order_workspace_directory, previous_workspace_directory),
        else: Application.delete_env(:aiur, :build_order_workspace_directory)

      File.rm_rf(directory)
    end)

    {:ok, pack_path: pack_path, status_path: PackPaths.status_path(pack_path), workspace_directory: workspace_directory}
  end

  def start_poller(pack_path, request_fun, opts \\ []) do
    start_supervised!(
      {PackStatus,
       name: nil,
       poll_on_start: false,
       paths_fun: fn -> [pack_path] end,
       repo_fun: fn -> {:ok, {"acme", "widgets"}} end,
       token_fun: fn -> {:ok, "token"} end,
       request_fun: request_fun,
       now_fun: Keyword.get(opts, :now_fun, fn -> ~U[2026-08-02 12:00:00Z] end)}
    )
  end

  def issues_response(issues) do
    test = self()

    fn %{method: :post, body: %{"query" => query}} ->
      send(test, {:query, query})
      {:ok, %{status: 200, body: %{"data" => %{"repository" => issues}}}}
    end
  end

  def grid do
    [root] = PlanningSource.catalog().data.entries
    {:ok, snapshot} = PlanningSource.demand(root.identity)

    snapshot
    |> BuildOrderPresenter.present(:unavailable, :unavailable)
    |> BuildOrderGridModel.build(nil)
  end

  def query_numbers(query) do
    ~r/i(\d+): issue\(number: (\d+)\)/
    |> Regex.scan(query, capture: :all_but_first)
    |> Enum.map(fn [alias_number, issue_number] ->
      assert alias_number == issue_number
      String.to_integer(issue_number)
    end)
  end

  def write_pack(base, name, repository, numbers) do
    path = Path.join([base, name, "build-order.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"repository" => repository, "tickets" => Enum.map(numbers, &%{"ticket" => &1})}))
    path
  end

  def start_pack_poller(paths, request_fun, opts) do
    start_supervised!(
      {PackStatus,
       name: nil, poll_on_start: false, paths_fun: fn -> paths end, planning_call_budget: Keyword.fetch!(opts, :planning_call_budget), token_fun: fn -> {:ok, "token"} end, request_fun: request_fun}
    )
  end

  def context_members(pack_path) do
    pack_path |> PackPaths.status_path() |> File.read!() |> Jason.decode!() |> Map.fetch!("members")
  end

  def await_task(task) do
    monitor = Process.monitor(task)
    assert_receive {:DOWN, ^monitor, :process, ^task, reason}, @async_assert_timeout
    reason in [:normal, :noproc]
  end
end
