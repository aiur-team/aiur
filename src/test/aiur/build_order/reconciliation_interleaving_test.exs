defmodule Aiur.BuildOrder.ReconciliationInterleavingTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.GitHubGraph.Reconciliation
  alias Aiur.GitHub.ResourceStore

  @owner "reconciliation-test"
  @repo "repo"
  @full "#{@owner}/#{@repo}"

  setup do
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Aiur.PubSub),
      do: start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})

    unless Process.whereis(ResourceStore), do: start_supervised!({ResourceStore, path: nil})
    ResourceStore.clear(:sub_issue, @owner, @repo)

    path =
      Path.join(
        System.tmp_dir!(),
        "membership-workflow-#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(path, "tracker:\n  kind: github\n  github:\n    repo: #{@full}\n")
    Process.put(:workflow_file_path_override, path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  test "a webhook addition and removal after fetch fence reject the stale replacement" do
    put_edge(10, true)
    :ok = ResourceStore.subscribe(:sub_issue)

    request = fn _ ->
      response = response([10])
      # Snapshot is ready, but the reconciliation has not replaced membership.
      # Another producer publishes a new edge and removes an old one meanwhile.
      task =
        Task.async(fn ->
          put_edge(592, true)
          put_edge(10, false)
        end)

      Task.await(task)
      {:ok, response}
    end

    assert {:error, :membership_changed} = Reconciliation.run(request_fun: request)
    assert edge(592)["present"] == true
    assert edge(10)["present"] == false
    refute_receive {:github_resource_changed, %{key: nil}}, 30

    # The next bounded attempt uses a new fence and converges on new truth.
    assert {:ok, :reconciled, %{roots: 1}} =
             Reconciliation.run(request_fun: fn _ -> {:ok, response([592, 609])} end)

    assert members() == [592, 609]
    assert :miss = ResourceStore.fetch(key(10))
  end

  test "replacement publishes one complete set and concurrent readers cannot see the cleared gap" do
    put_edge(10, true)
    assert {:ok, fence} = ResourceStore.membership_snapshot(@owner, @repo)
    :ok = ResourceStore.subscribe(:sub_issue)
    parent = self()

    reader =
      Task.async(fn ->
        :ok = ResourceStore.subscribe(:sub_issue)
        send(parent, :subscribed)

        receive do
          {:github_resource_changed, event} -> {event, members()}
        after
          1_000 -> flunk("membership notification missing")
        end
      end)

    assert_receive :subscribed

    assert :ok =
             ResourceStore.replace_membership(@owner, @repo, fence, [
               row(592, true),
               row(609, true)
             ])

    assert {%{key: nil, cleared: false, data?: true}, [592, 609]} = Task.await(reader)
    assert_receive {:github_resource_changed, %{key: nil, cleared: false}}
    refute_receive {:github_resource_changed, _}, 30
    assert members() == [592, 609]
  end

  test "membership readers and writers wait until an owner transaction finishes" do
    put_edge(10, true)
    parent = self()
    owner = :ets.info(ResourceStore.Table, :owner)

    held =
      Task.async(fn ->
        GenServer.call(
          owner,
          {:membership_access,
           fn ->
             send(parent, :locked)

             receive do
               :continue -> :ok
             end
           end}
        )
      end)

    assert_receive :locked

    writer =
      Task.async(fn ->
        send(parent, :writing)
        put_edge(592, true)
        send(parent, :written)
      end)

    reader =
      Task.async(fn ->
        send(parent, :reading)
        result = members()
        send(parent, :read)
        result
      end)

    assert_receive :writing
    assert_receive :reading
    refute_receive :written, 30
    refute_receive :read, 30
    send(owner, :continue)
    Task.await(held)
    Task.await(writer)
    assert Task.await(reader) in [[10], [10, 592]]
    assert_receive :read
    assert_receive :written
    assert members() == [10, 592]
  end

  defp key(n), do: ResourceStore.key(:sub_issue, @owner, @repo, "1:#{n}")

  defp row(n, present),
    do:
      {"1:#{n}",
       %{
         "present" => present,
         "parent_issue_number" => 1,
         "sub_issue_number" => n,
         "parent_issue_repo" => @full,
         "sub_issue_repo" => @full
       }}

  defp put_edge(n, present),
    do:
      ResourceStore.put_resource(key(n), elem(row(n, present), 1),
        source: :webhook,
        version: DateTime.to_iso8601(DateTime.utc_now())
      )

  defp edge(n) do
    {:ok, %{data: body}} = ResourceStore.fetch(key(n))
    body
  end

  defp members do
    ResourceStore.list(:sub_issue, @owner, @repo)
    |> Enum.filter(fn {_, entry} -> entry.data["present"] end)
    |> Enum.map(fn {_, entry} -> entry.data["sub_issue_number"] end)
    |> Enum.sort()
  end

  defp response(members) do
    root =
      issue_node(1)
      |> Map.put("labels", connection([%{"name" => "build-order"}]))
      |> Map.put("subIssues", connection(Enum.map(members, &issue_node/1)))

    %{
      status: 200,
      headers: [],
      body: %{"data" => %{"repository" => %{"issues" => connection([root])}}}
    }
  end

  defp connection(nodes),
    do: %{
      "nodes" => nodes,
      "totalCount" => length(nodes),
      "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
    }

  defp issue_node(n) do
    %{
      "id" => "I#{n}",
      "databaseId" => n,
      "number" => n,
      "title" => "Issue #{n}",
      "url" => "https://github.com/#{@full}/issues/#{n}",
      "state" => "OPEN",
      "stateReason" => nil,
      "parent" => nil,
      "updatedAt" => "2026-09-30T00:00:00Z",
      "createdAt" => "2026-09-30T00:00:00Z",
      "repository" => %{"name" => @repo, "owner" => %{"login" => @owner}},
      "labels" => connection([])
    }
  end
end
