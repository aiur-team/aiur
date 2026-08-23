defmodule Aiur.BuildOrder.PackStatusTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{PackPaths, PackStatus, ProviderHealth}
  alias Aiur.GitHub.Config
  alias Aiur.RepoBase
  alias AiurWeb.BuildOrder.{PlanningSource, RouteState}
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

  setup do
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

  defp start_poller(pack_path, request_fun, opts \\ []) do
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

    # Before the projection exists only part of completion resolves. The zero
    # is retained with an explicit partial state rather than becoming a bare,
    # exact-looking percentage.
    initial_completion = grid().overall_completion
    assert initial_completion.progress == 0
    assert initial_completion.progress_resolution == :partial

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
    assert grid.overall_completion.progress > 0
    assert Enum.find(grid.cards, &(&1.id == "4101")).state == :merged
    assert Enum.find(grid.cards, &(&1.id == "4101")).completion.progress == 100
    assert Enum.find(grid.cards, &(&1.id == "4103")).state != :merged
  end

  test "a failed refresh marks retained completion stale without discarding it", context do
    {:ok, response} = Agent.start_link(fn -> :success end)
    {:ok, clock} = Agent.start_link(fn -> ~U[2026-08-02 12:00:00Z] end)
    test = self()

    request_fun = fn _request ->
      case Agent.get(response, & &1) do
        :success ->
          send(test, {:successful_request, self()})

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "repository" => %{
                   "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"},
                   "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
                   "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
                 }
               }
             }
           }}

        :failure ->
          send(test, {:failed_request, self()})
          {:ok, %{status: 502, body: %{}}}
      end
    end

    poller = start_poller(context.pack_path, request_fun, now_fun: fn -> Agent.get(clock, & &1) end)

    Application.put_env(:aiur, :build_order_planning_pack, context.pack_path)

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      %{generation: 0, health: :healthy, freshness: %{status: :fresh}, members: []}
    end)

    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn -> PackStatus.health(poller) end)
    assert :ok = PackStatus.subscribe()

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_pack)
      Application.delete_env(:aiur, :build_order_planning_membership_snapshot)
    end)

    initial_generation = PlanningSource.catalog().generation

    assert :ok = PackStatus.refresh(poller)
    assert_receive {:successful_request, successful_task}, @async_assert_timeout
    assert await_task(successful_task)
    assert_receive {:build_order_pack_status_changed, %ProviderHealth{state: :healthy}}, @async_assert_timeout
    assert %ProviderHealth{state: :healthy, complete?: true, last_success_at: ~U[2026-08-02 12:00:00Z]} = PackStatus.health(poller)
    healthy_snapshot = PlanningSource.catalog()
    assert healthy_snapshot.health.state == :healthy
    assert healthy_snapshot.generation > initial_generation

    Agent.update(response, fn _ -> :failure end)
    Agent.update(clock, fn _ -> ~U[2026-08-02 12:05:00Z] end)

    assert :ok = PackStatus.refresh(poller)
    assert_receive {:failed_request, failed_task}, @async_assert_timeout
    assert await_task(failed_task)
    assert_receive {:build_order_pack_status_changed, %ProviderHealth{state: :stale}}, @async_assert_timeout

    assert %ProviderHealth{
             state: :stale,
             complete?: false,
             observed_at: ~U[2026-08-02 12:00:00Z],
             last_success_at: ~U[2026-08-02 12:00:00Z],
             last_attempt_at: ~U[2026-08-02 12:05:00Z]
           } = PackStatus.health(poller)

    snapshot = PlanningSource.catalog()
    assert snapshot.health.state == :stale
    assert snapshot.health.failure == :pack_status_refresh_failed
    assert snapshot.generation == healthy_snapshot.generation

    [root] = snapshot.data.entries
    {:ok, selected} = PlanningSource.demand(root.identity)
    grid = selected |> BuildOrderPresenter.present(:unavailable, :unavailable) |> BuildOrderGridModel.build(nil)

    assert Enum.find(grid.cards, &(&1.id == "4101")).state == :merged
    assert Enum.find(grid.cards, &(&1.id == "4101")).completion.progress == 100
  end

  test "preserves unrelated status keys and earlier members", context do
    File.write!(context.status_path, ~s({"state":"active","members":{"4999":"completed"}}))

    poller =
      start_poller(
        context.pack_path,
        issues_response(%{
          "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"},
          "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
          "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
        })
      )

    assert {:ok, [_written]} = PackStatus.refresh_sync(poller)

    status = Jason.decode!(File.read!(context.status_path))
    assert status["state"] == "active"
    assert status["members"]["4999"] == "completed"
    assert %{"lifecycle" => "completed"} = status["members"]["4101"]
  end

  test "does not rewrite an unchanged projection", context do
    {:ok, clock} = Agent.start_link(fn -> ~U[2026-08-02 12:00:00Z] end)
    assert :ok = PackStatus.subscribe()

    poller =
      start_poller(
        context.pack_path,
        issues_response(%{
          "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"},
          "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
          "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
        }),
        now_fun: fn -> Agent.get(clock, & &1) end
      )

    assert {:ok, [_written]} = PackStatus.refresh_sync(poller)
    assert_receive {:build_order_pack_status_changed, %ProviderHealth{generation: generation}}
    body = File.read!(context.status_path)

    Agent.update(clock, fn _ -> ~U[2026-08-02 12:05:00Z] end)
    assert {:ok, [_written]} = PackStatus.refresh_sync(poller)

    # If the second cycle wrote, its later observed_at would change the body.
    assert File.read!(context.status_path) == body
    refute File.read!(context.status_path) =~ "2026-08-02T12:05:00Z"
    assert PackStatus.health(poller).generation == generation
    refute_receive {:build_order_pack_status_changed, _health}
  end

  test "chunks 51 promoted members into GraphQL requests of 50 and 1", context do
    tickets = Enum.map(1..51, &%{"ticket" => &1})
    File.write!(context.pack_path, Jason.encode!(%{"repository" => "acme/widgets", "tickets" => tickets}))
    test = self()

    request_fun = fn %{method: :post, body: %{"query" => query}} ->
      numbers = query_numbers(query)

      send(test, {:query_numbers, numbers})

      issues =
        Map.new(numbers, fn number ->
          {"i#{number}", %{"number" => number, "state" => "OPEN", "stateReason" => nil}}
        end)

      {:ok, %{status: 200, body: %{"data" => %{"repository" => issues}}}}
    end

    poller = start_poller(context.pack_path, request_fun)

    assert {:ok, [_reconciled]} = PackStatus.refresh_sync(poller)
    assert_receive {:query_numbers, first_chunk}
    assert_receive {:query_numbers, second_chunk}
    assert first_chunk == Enum.to_list(1..50)
    assert second_chunk == [51]

    assert %{"members" => members} = context.status_path |> File.read!() |> Jason.decode!()
    assert map_size(members) == 51
  end

  test "bounds a multi-pack refresh to the cycle-wide planning call budget", context do
    paths =
      Enum.map(0..2, fn pack_index ->
        numbers = Enum.to_list((pack_index * 100 + 1)..(pack_index * 100 + 100))
        pack_path = Path.join([Path.dirname(Path.dirname(context.pack_path)), "budget-#{pack_index}", "build-order.json"])
        File.mkdir_p!(Path.dirname(pack_path))
        File.write!(pack_path, Jason.encode!(%{"repository" => "acme/widgets", "tickets" => Enum.map(numbers, &%{"ticket" => &1})}))
        pack_path
      end)

    retained_path = paths |> List.last() |> PackPaths.status_path()
    retained = ~s({"members":{"201":"completed"}})
    File.write!(retained_path, retained)
    test = self()

    request_fun = fn %{method: :post, body: %{"query" => query}} ->
      numbers = query_numbers(query)

      send(test, {:budget_query, numbers})

      issues =
        Map.new(numbers, fn number ->
          {"i#{number}", %{"number" => number, "state" => "OPEN", "stateReason" => nil}}
        end)

      {:ok, %{status: 200, body: %{"data" => %{"repository" => issues}}}}
    end

    poller =
      start_supervised!({PackStatus, name: nil, poll_on_start: false, paths_fun: fn -> paths end, planning_call_budget: 4, token_fun: fn -> {:ok, "token"} end, request_fun: request_fun})

    assert {:error, {:pack_refresh_failed, errors}} = PackStatus.refresh_sync(poller)
    assert :planning_call_budget_exhausted in errors

    queries = for _ <- 1..4, do: receive(do: ({:budget_query, numbers} -> numbers))
    assert Enum.map(queries, &length/1) == [50, 50, 50, 50]
    refute_receive {:budget_query, _numbers}

    assert File.exists?(PackPaths.status_path(Enum.at(paths, 0)))
    assert File.exists?(PackPaths.status_path(Enum.at(paths, 1)))
    assert File.read!(retained_path) == retained

    assert %ProviderHealth{state: :unavailable, complete?: false, failure: :planning_call_budget_exhausted} =
             PackStatus.health(poller)

    assert {:error, {:pack_refresh_failed, _errors}} = PackStatus.refresh_sync(poller)
    second_cycle = for _ <- 1..4, do: receive(do: ({:budget_query, numbers} -> numbers))
    assert List.flatten(second_cycle) |> Enum.take(100) == Enum.to_list(201..300)
    refute File.read!(retained_path) == retained
  end

  test "deduplicates overlapping members across packs in one repository", context do
    base = Path.dirname(Path.dirname(context.pack_path))
    first = write_pack(base, "dedupe-first", "acme/widgets", [1, 2])
    second = write_pack(base, "dedupe-second", "acme/widgets", [2, 3])
    test = self()

    request_fun = fn %{body: %{"query" => query}} ->
      numbers = query_numbers(query)
      send(test, {:dedupe_query, numbers})
      issues = Map.new(numbers, &{"i#{&1}", %{"number" => &1, "state" => "OPEN", "stateReason" => nil}})
      {:ok, %{status: 200, body: %{"data" => %{"repository" => issues}}}}
    end

    poller = start_pack_poller([first, second], request_fun, planning_call_budget: 4)

    assert {:ok, [^first, ^second]} = PackStatus.refresh_sync(poller)
    assert_receive {:dedupe_query, [1, 2, 3]}
    refute_receive {:dedupe_query, _numbers}
    assert context_members(first) |> Map.keys() |> Enum.sort() == ["1", "2"]
    assert context_members(second) |> Map.keys() |> Enum.sort() == ["2", "3"]
  end

  test "rotates exhausted budget across repositories on later cycles", context do
    base = Path.dirname(Path.dirname(context.pack_path))
    first = write_pack(base, "repo-first", "acme/widgets", [1])
    second = write_pack(base, "repo-second", "other/project", [2])
    retained_path = PackPaths.status_path(second)
    retained = ~s({"members":{"2":"completed"}})
    File.write!(retained_path, retained)
    test = self()

    request_fun = fn %{body: %{"query" => query, "variables" => variables}} ->
      [number] = query_numbers(query)
      send(test, {:repository_query, variables, number})
      issues = %{"i#{number}" => %{"number" => number, "state" => "OPEN", "stateReason" => nil}}
      {:ok, %{status: 200, body: %{"data" => %{"repository" => issues}}}}
    end

    poller = start_pack_poller([first, second], request_fun, planning_call_budget: 1)

    assert {:error, _reason} = PackStatus.refresh_sync(poller)
    assert_receive {:repository_query, %{"owner" => "acme", "name" => "widgets"}, 1}
    assert File.read!(retained_path) == retained

    assert {:error, _reason} = PackStatus.refresh_sync(poller)
    assert_receive {:repository_query, %{"owner" => "other", "name" => "project"}, 2}
    refute File.read!(retained_path) == retained
    refute_receive {:repository_query, _variables, _number}
  end

  test "an invalid lifecycle in the second chunk preserves the projection", context do
    tickets = Enum.map(1..51, &%{"ticket" => &1})
    File.write!(context.pack_path, Jason.encode!(%{"repository" => "acme/widgets", "tickets" => tickets}))
    previous = ~s({"members":{"1":"completed"}})
    File.write!(context.status_path, previous)

    request_fun = fn %{method: :post, body: %{"query" => query}} ->
      numbers = query_numbers(query)

      issues =
        Map.new(numbers, fn number ->
          state = if number == 51, do: "MYSTERY", else: "OPEN"
          {"i#{number}", %{"number" => number, "state" => state, "stateReason" => nil}}
        end)

      {:ok, %{status: 200, body: %{"data" => %{"repository" => issues}}}}
    end

    poller = start_poller(context.pack_path, request_fun)

    assert {:error, {:pack_refresh_failed, [incomplete_graphql_response: ["51"]]}} = PackStatus.refresh_sync(poller)
    assert File.read!(context.status_path) == previous
  end

  test "a first-chunk failure halts later requests and preserves the projection", context do
    tickets = Enum.map(1..51, &%{"ticket" => &1})
    File.write!(context.pack_path, Jason.encode!(%{"repository" => "acme/widgets", "tickets" => tickets}))
    previous = ~s({"members":{"1":"completed"}})
    File.write!(context.status_path, previous)
    test = self()

    poller =
      start_poller(context.pack_path, fn _request ->
        send(test, :failed_chunk_request)
        {:ok, %{status: 502, body: %{}}}
      end)

    assert {:error, _reason} = PackStatus.refresh_sync(poller)
    assert_receive :failed_chunk_request
    refute_receive :failed_chunk_request
    assert File.read!(context.status_path) == previous
    assert PackStatus.health(poller).state == :unavailable
  end

  test "an unknown closed reason preserves the projection", context do
    previous = ~s({"members":{"4101":"completed"}})
    File.write!(context.status_path, previous)

    poller =
      start_poller(
        context.pack_path,
        issues_response(%{
          "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => nil},
          "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
          "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
        })
      )

    assert {:error, {:pack_refresh_failed, [incomplete_graphql_response: ["4101"]]}} = PackStatus.refresh_sync(poller)
    assert File.read!(context.status_path) == previous
  end

  test "queries the repository declared by the pack", context do
    File.write!(context.pack_path, String.replace(@pack, "acme/widgets", "other/project"))
    test = self()

    request_fun = fn %{method: :post, body: %{"variables" => variables}} ->
      send(test, {:variables, variables})

      issues = %{
        "i4101" => %{"number" => 4101, "state" => "OPEN", "stateReason" => nil},
        "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
        "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
      }

      {:ok, %{status: 200, body: %{"data" => %{"repository" => issues}}}}
    end

    poller = start_poller(context.pack_path, request_fun)

    assert {:ok, [_written]} = PackStatus.refresh_sync(poller)
    assert_receive {:variables, %{"owner" => "other", "name" => "project"}}
  end

  test "default polling ignores foreign override packs", _context do
    suffix = System.unique_integer([:positive])
    state_root = Path.join(System.tmp_dir!(), "pack-status-tracked-state-#{suffix}")
    override_directory = Path.join(System.tmp_dir!(), "pack-status-tracked-override-#{suffix}")
    repository = Config.repo()
    previous_root = Application.get_env(:aiur, :repo_base_root)
    previous_pack = Application.get_env(:aiur, :build_order_planning_pack)
    previous_packs = Application.get_env(:aiur, :build_order_planning_packs)
    previous_dirs = System.get_env("AIUR_BUILD_ORDER_DIRS")

    Application.put_env(:aiur, :repo_base_root, state_root)
    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.delete_env(:aiur, :build_order_planning_packs)
    System.put_env("AIUR_BUILD_ORDER_DIRS", override_directory)

    state_path = Path.join([RepoBase.builds_path("https://github.com/#{repository}.git"), "tracked", "build-order.json"])
    foreign_path = Path.join(override_directory, "foreign.json")

    File.mkdir_p!(Path.dirname(state_path))
    File.mkdir_p!(override_directory)
    File.write!(state_path, String.replace(@pack, "acme/widgets", repository))
    File.write!(foreign_path, String.replace(@pack, "acme/widgets", "other/project"))

    on_exit(fn ->
      if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
      if previous_pack, do: Application.put_env(:aiur, :build_order_planning_pack, previous_pack), else: Application.delete_env(:aiur, :build_order_planning_pack)
      if previous_packs, do: Application.put_env(:aiur, :build_order_planning_packs, previous_packs), else: Application.delete_env(:aiur, :build_order_planning_packs)
      if previous_dirs, do: System.put_env("AIUR_BUILD_ORDER_DIRS", previous_dirs), else: System.delete_env("AIUR_BUILD_ORDER_DIRS")
      File.rm_rf(state_root)
      File.rm_rf(override_directory)
    end)

    test = self()

    poller =
      start_supervised!(
        {PackStatus,
         name: nil,
         poll_on_start: false,
         planning_call_budget: 1,
         token_fun: fn -> {:ok, "token"} end,
         request_fun: fn %{body: %{"variables" => variables}} ->
           send(test, {:repository_query, variables})
           issues = Map.new(4101..4103, &{"i#{&1}", %{"number" => &1, "state" => "OPEN", "stateReason" => nil}})
           {:ok, %{status: 200, body: %{"data" => %{"repository" => issues}}}}
         end}
      )

    assert {:ok, [^state_path]} = PackStatus.refresh_sync(poller)
    assert_receive {:repository_query, %{"owner" => owner, "name" => name}}
    assert String.downcase("#{owner}/#{name}") == String.downcase(repository)
    refute_receive {:repository_query, _variables}
    refute File.exists?(PackPaths.status_path(foreign_path))
  end

  test "default polling projects lifecycle for a workspace-published pack", context do
    suffix = System.unique_integer([:positive])
    state_root = Path.join(System.tmp_dir!(), "pack-status-workspace-state-#{suffix}")
    workspace_directory = context.workspace_directory
    workspace_path = Path.join(workspace_directory, "pack-status-workspace-#{suffix}.json")
    status_path = PackPaths.status_path(workspace_path)
    repository = Config.repo()
    previous_root = Application.get_env(:aiur, :repo_base_root)
    previous_pack = Application.get_env(:aiur, :build_order_planning_pack)
    previous_packs = Application.get_env(:aiur, :build_order_planning_packs)
    previous_dirs = System.get_env("AIUR_BUILD_ORDER_DIRS")

    Application.put_env(:aiur, :repo_base_root, state_root)
    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.delete_env(:aiur, :build_order_planning_packs)
    System.delete_env("AIUR_BUILD_ORDER_DIRS")

    File.mkdir_p!(workspace_directory)
    File.write!(workspace_path, String.replace(@pack, "acme/widgets", repository))
    File.write!(status_path, ~s({"operator_annotation":"keep","members":{}}))

    on_exit(fn ->
      if previous_root,
        do: Application.put_env(:aiur, :repo_base_root, previous_root),
        else: Application.delete_env(:aiur, :repo_base_root)

      if previous_pack,
        do: Application.put_env(:aiur, :build_order_planning_pack, previous_pack),
        else: Application.delete_env(:aiur, :build_order_planning_pack)

      if previous_packs,
        do: Application.put_env(:aiur, :build_order_planning_packs, previous_packs),
        else: Application.delete_env(:aiur, :build_order_planning_packs)

      if previous_dirs,
        do: System.put_env("AIUR_BUILD_ORDER_DIRS", previous_dirs),
        else: System.delete_env("AIUR_BUILD_ORDER_DIRS")

      File.rm_rf(state_root)
    end)

    test = self()

    poller =
      start_supervised!(
        {PackStatus,
         name: nil,
         poll_on_start: false,
         token_fun: fn -> {:ok, "token"} end,
         request_fun: fn %{body: %{"variables" => variables}} ->
           send(test, {:workspace_repository_query, variables})

           issues =
             Map.new(4101..4103, fn number ->
               {"i#{number}", %{"number" => number, "state" => "OPEN", "stateReason" => nil}}
             end)

           {:ok, %{status: 200, body: %{"data" => %{"repository" => issues}}}}
         end}
      )

    assert {:ok, [^workspace_path]} = PackStatus.refresh_sync(poller)
    assert_receive {:workspace_repository_query, %{"owner" => owner, "name" => name}}
    assert String.downcase("#{owner}/#{name}") == String.downcase(repository)
    assert %{"operator_annotation" => "keep"} = status_path |> File.read!() |> Jason.decode!()

    catalog = PlanningSource.catalog()
    [root] = catalog.data.entries
    assert root.identity.identifier == "9900"
    assert root.progress == 0

    {route, []} = RouteState.new("workspace-published") |> RouteState.navigate("9900")
    {route, [{:activate, identity}]} = RouteState.put_catalog(route, catalog)
    assert identity == root.identity
    assert RouteState.status(route) == :selected_loading
  end

  test "default polling surfaces malformed tracked manifests", _context do
    suffix = System.unique_integer([:positive])
    state_root = Path.join(System.tmp_dir!(), "pack-status-malformed-state-#{suffix}")
    repository = Config.repo()
    previous_root = Application.get_env(:aiur, :repo_base_root)
    previous_pack = Application.get_env(:aiur, :build_order_planning_pack)
    previous_packs = Application.get_env(:aiur, :build_order_planning_packs)
    previous_dirs = System.get_env("AIUR_BUILD_ORDER_DIRS")

    Application.put_env(:aiur, :repo_base_root, state_root)
    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.delete_env(:aiur, :build_order_planning_packs)
    System.delete_env("AIUR_BUILD_ORDER_DIRS")

    state_path = Path.join([RepoBase.builds_path("https://github.com/#{repository}.git"), "malformed", "build-order.json"])
    File.mkdir_p!(Path.dirname(state_path))
    File.write!(state_path, ~s({"repository":123,"tickets":[]}))

    on_exit(fn ->
      if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
      if previous_pack, do: Application.put_env(:aiur, :build_order_planning_pack, previous_pack), else: Application.delete_env(:aiur, :build_order_planning_pack)
      if previous_packs, do: Application.put_env(:aiur, :build_order_planning_packs, previous_packs), else: Application.delete_env(:aiur, :build_order_planning_packs)
      if previous_dirs, do: System.put_env("AIUR_BUILD_ORDER_DIRS", previous_dirs), else: System.delete_env("AIUR_BUILD_ORDER_DIRS")
      File.rm_rf(state_root)
    end)

    poller =
      start_supervised!({PackStatus, name: nil, poll_on_start: false, token_fun: fn -> {:ok, "token"} end, request_fun: fn _request -> flunk("must not query a malformed manifest") end})

    assert {:error, {:pack_refresh_failed, [{^state_path, {:error, :invalid_pack}}]}} = PackStatus.refresh_sync(poller)
  end

  test "a failed tracker read leaves the previous projection intact", context do
    File.write!(context.status_path, ~s({"members":{"4101":"completed"}}))

    poller =
      start_poller(context.pack_path, fn _request ->
        {:ok, %{status: 502, body: %{}}}
      end)

    assert {:error, _reason} = PackStatus.refresh_sync(poller)
    assert Jason.decode!(File.read!(context.status_path)) == %{"members" => %{"4101" => "completed"}}
  end

  test "an incomplete tracker response leaves the previous projection intact", context do
    previous = ~s({"members":{"4101":"completed","4102":"open","4103":"open"}})
    File.write!(context.status_path, previous)

    poller =
      start_poller(
        context.pack_path,
        issues_response(%{"i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"}})
      )

    assert {:error, {:pack_refresh_failed, [incomplete]}} = PackStatus.refresh_sync(poller)
    assert inspect(incomplete) =~ "incomplete_graphql_response"
    assert File.read!(context.status_path) == previous
    assert %ProviderHealth{state: :unavailable, complete?: false, failure: :pack_status_refresh_failed} = PackStatus.health(poller)
  end

  test "a synchronous refresh refuses to overlap an async reconcile", context do
    test = self()
    assert :ok = PackStatus.subscribe()

    poller =
      start_poller(context.pack_path, fn _request ->
        send(test, {:refresh_started, self()})

        receive do
          :finish_refresh ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "repository" => %{
                     "i4101" => %{"number" => 4101, "state" => "OPEN", "stateReason" => nil},
                     "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
                     "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
                   }
                 }
               }
             }}
        end
      end)

    assert :ok = PackStatus.refresh(poller)
    assert_receive {:refresh_started, task}, @async_assert_timeout
    assert {:error, :refresh_in_progress} = PackStatus.refresh_sync(poller)

    send(task, :finish_refresh)
    assert await_task(task)
    assert_receive {:build_order_pack_status_changed, %ProviderHealth{state: :healthy}}, @async_assert_timeout
    assert PackStatus.health(poller).state == :healthy
  end

  test "default discovery reconciles the configured planning pack", context do
    Application.put_env(:aiur, :build_order_planning_pack, context.pack_path)
    on_exit(fn -> Application.delete_env(:aiur, :build_order_planning_pack) end)

    poller =
      start_supervised!(
        {PackStatus,
         name: nil,
         poll_on_start: false,
         repo_fun: fn -> {:ok, {"acme", "widgets"}} end,
         token_fun: fn -> {:ok, "token"} end,
         request_fun:
           issues_response(%{
             "i4101" => %{"number" => 4101, "state" => "OPEN", "stateReason" => nil},
             "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
             "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
           })}
      )

    assert {:ok, [written]} = PackStatus.refresh_sync(poller)
    assert written == context.pack_path
    assert File.exists?(context.status_path)
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

    assert %ProviderHealth{state: :unavailable, complete?: false, failure: :pack_status_refresh_failed} =
             PackStatus.health(poller)
  end

  test "a restarted poller keeps health generations monotonic", context do
    {:ok, response} = Agent.start_link(fn -> "COMPLETED" end)

    request_fun = fn _request ->
      reason = Agent.get(response, & &1)

      issues = %{
        "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => reason},
        "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
        "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
      }

      {:ok, %{status: 200, body: %{"data" => %{"repository" => issues}}}}
    end

    opts = [
      name: nil,
      poll_on_start: false,
      paths_fun: fn -> [context.pack_path] end,
      token_fun: fn -> {:ok, "token"} end,
      request_fun: request_fun
    ]

    first = start_supervised!({PackStatus, opts})
    assert {:ok, [_written]} = PackStatus.refresh_sync(first)
    first_generation = PackStatus.health(first).generation

    Agent.update(response, fn _ -> nil end)
    assert {:error, _reason} = PackStatus.refresh_sync(first)
    second_generation = PackStatus.health(first).generation
    assert second_generation == first_generation

    Agent.update(response, fn _ -> "NOT_PLANNED" end)
    assert {:ok, [_written]} = PackStatus.refresh_sync(first)
    last_generation = PackStatus.health(first).generation
    assert last_generation > second_generation
    assert :ok = stop_supervised(PackStatus)

    second = start_supervised!({PackStatus, name: nil, poll_on_start: false})

    assert PackStatus.health(second).generation > last_generation
  end

  test "a corrupt status projection remains intact", context do
    previous = "{not-json"
    File.write!(context.status_path, previous)

    poller =
      start_poller(
        context.pack_path,
        issues_response(%{
          "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"},
          "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
          "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
        })
      )

    assert {:error, {:pack_refresh_failed, [:invalid_status]}} = PackStatus.refresh_sync(poller)
    assert File.read!(context.status_path) == previous
  end

  test "a changed sibling advances generation when another pack fails", context do
    invalid_pack = Path.join(Path.dirname(context.pack_path), "invalid.json")
    File.write!(invalid_pack, "not-json")

    poller =
      start_supervised!(
        {PackStatus,
         name: nil,
         poll_on_start: false,
         paths_fun: fn -> [context.pack_path, invalid_pack] end,
         token_fun: fn -> {:ok, "token"} end,
         request_fun:
           issues_response(%{
             "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"},
             "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
             "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
           })}
      )

    initial_generation = PackStatus.health(poller).generation

    assert {:error, {:pack_refresh_failed, [_invalid]}} = PackStatus.refresh_sync(poller)
    assert PackStatus.health(poller).generation > initial_generation
    assert %{"members" => %{"4101" => %{"lifecycle" => "completed"}}} = Jason.decode!(File.read!(context.status_path))
  end

  defp grid do
    [root] = PlanningSource.catalog().data.entries
    {:ok, snapshot} = PlanningSource.demand(root.identity)

    snapshot
    |> BuildOrderPresenter.present(:unavailable, :unavailable)
    |> BuildOrderGridModel.build(nil)
  end

  defp query_numbers(query) do
    ~r/i(\d+): issue\(number: (\d+)\)/
    |> Regex.scan(query, capture: :all_but_first)
    |> Enum.map(fn [alias_number, issue_number] ->
      assert alias_number == issue_number
      String.to_integer(issue_number)
    end)
  end

  defp write_pack(base, name, repository, numbers) do
    path = Path.join([base, name, "build-order.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"repository" => repository, "tickets" => Enum.map(numbers, &%{"ticket" => &1})}))
    path
  end

  defp start_pack_poller(paths, request_fun, opts) do
    start_supervised!(
      {PackStatus,
       name: nil, poll_on_start: false, paths_fun: fn -> paths end, planning_call_budget: Keyword.fetch!(opts, :planning_call_budget), token_fun: fn -> {:ok, "token"} end, request_fun: request_fun}
    )
  end

  defp context_members(pack_path) do
    pack_path |> PackPaths.status_path() |> File.read!() |> Jason.decode!() |> Map.fetch!("members")
  end

  defp await_task(task) do
    monitor = Process.monitor(task)
    assert_receive {:DOWN, ^monitor, :process, ^task, reason}, @async_assert_timeout
    reason in [:normal, :noproc]
  end
end
