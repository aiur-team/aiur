defmodule Aiur.BuildOrder.PackStatus.ReconcileTest do
  use Aiur.BuildOrder.PackStatusCase

  # PackStatus is deliberately NOT demand-gated: it writes the daemon-owned
  # status.json projection the planning contract names authoritative, so the
  # sweep reconciles it on every tick whether or not a page is open. demanded?/0
  # answering true unconditionally is what keeps the sweep's uniform protocol
  # honest — see the moduledoc for the full reasoning.
  test "always reports demanded, so the sweep never skips it", context do
    poller =
      start_poller(context.pack_path, fn _request ->
        {:ok, %{status: 200, body: %{"data" => %{"repository" => %{}}}}}
      end)

    assert PackStatus.demanded?(poller) == true
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
    assert_receive {:query_numbers, first_chunk}, 1000
    assert_receive {:query_numbers, second_chunk}, 1000
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
    refute_receive {:budget_query, _numbers}, 100

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

  test "budget-limited cycles resolve pack tickets from two roots by issue number", context do
    pack = Jason.decode!(@pack)

    tickets =
      Enum.map(1..72, fn i ->
        hd(pack["tickets"]) |> Map.put("id", "SECOND-#{i}") |> Map.put("ticket", 5000 + i)
      end)

    pack = Map.put(pack, "tickets", [hd(pack["tickets"]) | tickets])
    File.write!(context.pack_path, Jason.encode!(pack))
    Application.put_env(:aiur, :build_order_planning_pack, context.pack_path)
    on_exit(fn -> Application.delete_env(:aiur, :build_order_planning_pack) end)

    request_fun = fn %{body: %{"query" => query}} ->
      refute query =~ "subIssues"

      issues =
        Map.new(query_numbers(query), fn number ->
          {"i#{number}", %{"number" => number, "state" => "CLOSED", "stateReason" => "COMPLETED"}}
        end)

      {:ok, %{status: 200, body: %{"data" => %{"repository" => issues}}}}
    end

    poller = start_pack_poller([context.pack_path], request_fun, planning_call_budget: 1)
    assert {:error, _} = PackStatus.refresh_sync(poller)
    assert map_size(context_members(context.pack_path)) == 50
    assert {:error, _} = PackStatus.refresh_sync(poller)
    [root] = PlanningSource.catalog().data.entries
    {:ok, snapshot} = PlanningSource.selected(root.identity)
    # The selected root's GitHub graph contains only 4101; 5001..5072 belong
    # to a second root and must be hydrated from their issue-number status facts.
    primary_graph = %{snapshot | data: %{snapshot.data | members: Enum.filter(snapshot.data.members, &(&1.identity.identifier == "4101"))}}
    {:ok, combined} = PackOverlay.selected(root.identity, {:ok, primary_graph})
    assert length(combined.data.members) == 73
    assert Enum.all?(combined.data.members, &(&1.lifecycle.state == :closed and &1.lifecycle.state_reason == :completed))
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
    assert_receive {:dedupe_query, [1, 2, 3]}, 1000
    refute_receive {:dedupe_query, _numbers}, 100
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
    assert_receive {:repository_query, %{"owner" => "acme", "name" => "widgets"}, 1}, 1000
    assert File.read!(retained_path) == retained

    assert {:error, _reason} = PackStatus.refresh_sync(poller)
    assert_receive {:repository_query, %{"owner" => "other", "name" => "project"}, 2}, 1000
    refute File.read!(retained_path) == retained
    refute_receive {:repository_query, _variables, _number}, 100
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
    assert_receive {:variables, %{"owner" => "other", "name" => "project"}}, 1000
  end

  test "default polling ignores foreign override packs", _context do
    state_root = Aiur.TestSupport.tmp_root!("pack-status-tracked-state")
    override_directory = Aiur.TestSupport.tmp_root!("pack-status-tracked-override")
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
    assert_receive {:repository_query, %{"owner" => owner, "name" => name}}, 1000
    assert String.downcase("#{owner}/#{name}") == String.downcase(repository)
    refute_receive {:repository_query, _variables}, 100
    refute File.exists?(PackPaths.status_path(foreign_path))
  end

  test "default polling projects lifecycle for a workspace-published pack", context do
    suffix = System.unique_integer([:positive])
    state_root = Aiur.TestSupport.tmp_root!("pack-status-workspace-state")
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
    assert_receive {:workspace_repository_query, %{"owner" => owner, "name" => name}}, 1000
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
    state_root = Aiur.TestSupport.tmp_root!("pack-status-malformed-state")
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
end
