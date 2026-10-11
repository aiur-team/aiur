defmodule Aiur.RunTelemetry.RepoTimelineTest do
  use ExUnit.Case, async: true
  alias Aiur.RunTelemetry.RepoTimeline

  setup do
    directory = Path.join(System.tmp_dir!(), "repo-timeline-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, path: Path.join(directory, "repo-timeline.ndjson")}
  end

  test "chronological intervals ignore pending, preserve non-ticket merges and redact messages", %{path: path} do
    commits = [commit("a", 1, "SUCCESS"), commit("b", 2, "FAILURE"), commit("c", 3, "PENDING"), commit("d", 4, "FAILURE"), commit("e", 5, "SUCCESS")]

    commits =
      List.update_at(
        commits,
        4,
        &Map.merge(&1, %{"message" => "Revert \"Add X (#123)\"\n\nThis reverts commit abc.", "associatedPullRequests" => %{"nodes" => [%{"number" => 77, "headRefName" => "outside"}]}})
      )

    commits = List.update_at(commits, 0, &Map.put(&1, "associatedPullRequests", %{"nodes" => [%{"number" => 76, "headRefName" => "aiur/3797-facts"}]}))
    tags = [%{"name" => "v1", "target" => %{"__typename" => "Tag", "target" => %{"__typename" => "Commit", "oid" => "e", "committedDate" => timestamp(5)}}}]
    worker = worker(path, fn request -> response(Enum.reverse(commits), tags, request) end)
    assert :ok = RepoTimeline.capture(worker)
    rows = rows(path)
    assert Enum.map(Enum.filter(rows, &(&1["type"] == "commit")), & &1["sha"]) == ~w(a b c d e)
    assert boundaries(rows) == [{"main_red_start", "b"}, {"main_red_end", "e"}]
    assert Enum.find(rows, &(&1["sha"] == "a"))["ticket"] == "3797"
    assert %{"revert_of" => "abc", "pr_number" => 77, "ticket" => nil} = Enum.find(rows, &(&1["sha"] == "e" and &1["type"] == "commit"))
    assert %{"type" => "tag", "tag" => "v1", "sha" => "e"} = List.last(rows)
    contents = File.read!(path)
    refute contents =~ "message"
    refute contents =~ "Add X"
    refute contents =~ "headRefName"
    assert :ok = RepoTimeline.capture(worker)
    assert File.read!(path) == contents
  end

  test "boot reads configured base and persisted cursor closes red across restart", %{path: path} do
    owner = self()

    first =
      worker(
        path,
        fn request ->
          send(owner, {:first_request, request.body["variables"]})
          response([commit("a", 1, "SUCCESS"), commit("b", 2, "FAILURE")], [], request)
        end,
        boot_capture: true
      )

    assert_receive {:first_request, %{"since" => nil, "branch" => "refs/heads/integration"}}, 5_000
    assert :ok = RepoTimeline.capture(first)
    GenServer.stop(first)

    second =
      worker(path, fn request ->
        send(owner, {:second_request, request.body["variables"]})
        response([commit("c", 3, "SUCCESS"), commit("b", 2, "FAILURE")], [], request)
      end)

    assert :ok = RepoTimeline.capture(second)
    assert_receive {:second_request, %{"since" => "2026-10-09T00:00:02Z"}}, 500
    assert boundaries(rows(path)) == [{"main_red_start", "b"}, {"main_red_end", "c"}]
  end

  test "disabled capture makes zero requests", %{path: path} do
    worker = worker(path, fn _ -> flunk("disabled capture read GitHub") end, enabled_fun: fn -> false end)
    assert :ok = RepoTimeline.capture(worker)
    refute File.exists?(path)
  end

  test "budget hold keeps cursor and retries on timer", %{path: path} do
    owner = self()
    counter = :atomics.new(1, [])

    worker =
      worker(
        path,
        fn request ->
          send(owner, {:attempt, request.body["variables"]["since"]})

          if :atomics.add_get(counter, 1, 1) == 1 do
            {:error, {:aiur, :locally_held, %{reason: :shared_budget}}}
          else
            response([commit("a", 1, "SUCCESS")], [], request)
          end
        end,
        retry_ms: 10
      )

    assert {:error, {:aiur, :locally_held, _hold}} = RepoTimeline.capture(worker)
    assert_receive {:attempt, nil}, 500
    assert_receive {:attempt, nil}, 5_000
    assert :ok = RepoTimeline.capture(worker)
    assert [%{"type" => "commit", "sha" => "a"}] = rows(path)
  end

  test "paginates history and tags without losing old commits", %{path: path} do
    owner = self()

    request = fn request ->
      variables = request.body["variables"]
      send(owner, {:cursor, variables["historyCursor"], variables["tagCursor"]})

      if variables["historyCursor"] == nil do
        response([commit("b", 2, "FAILURE")], [tag("v2", "b", 2)], request, {true, "h1"}, {true, "t1"})
      else
        response([commit("a", 1, "SUCCESS")], [tag("v1", "a", 1)], request)
      end
    end

    assert :ok = RepoTimeline.capture(worker(path, request))
    assert_receive {:cursor, nil, nil}, 500
    assert_receive {:cursor, "h1", "t1"}, 500
    assert Enum.count(rows(path), &(&1["type"] == "commit")) == 2
    assert Enum.count(rows(path), &(&1["type"] == "tag")) == 2
  end

  test "cyclic pagination persists no incomplete history", %{path: path} do
    request = fn request -> response([commit("a", 1, "SUCCESS")], [], request, {true, "same"}) end
    assert {:error, :pagination_cycle} = RepoTimeline.capture(worker(path, request))
    refute File.exists?(path)
  end

  test "headline-only revert resolves original PR merge SHA without storing prose", %{path: path} do
    revert = commit("b", 2, "SUCCESS") |> Map.put("messageHeadline", "Revert \"Add X (#123)\"")
    owner = self()

    request = fn request ->
      assert request.caller == "analytics_repo_timeline"

      if request.body["variables"]["number"] do
        send(owner, {:revert_request, request.body["variables"]["number"]})
        {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequest" => %{"mergeCommit" => %{"oid" => "abc"}}}}}, headers: %{}}}
      else
        response([revert], [], request)
      end
    end

    assert :ok = RepoTimeline.capture(worker(path, request))
    assert_receive {:revert_request, 123}, 500
    assert [%{"revert_of" => "abc"}] = rows(path)
    refute File.read!(path) =~ "Add X"
  end

  test "nested annotated tags are peeled to the actual commit", %{path: path} do
    tags = [%{"name" => "nested", "target" => %{"__typename" => "Tag", "target" => %{"__typename" => "Tag", "oid" => "tag-object"}}}]
    owner = self()

    request = fn request ->
      assert request.caller == "analytics_repo_timeline"

      if request.body["variables"]["oid"] do
        send(owner, {:tag_request, request.body["variables"]["oid"]})
        target = %{"__typename" => "Commit", "oid" => "a", "committedDate" => timestamp(1)}
        {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"object" => %{"target" => target}}}}, headers: %{}}}
      else
        response([commit("a", 1, "SUCCESS")], tags, request)
      end
    end

    assert :ok = RepoTimeline.capture(worker(path, request))
    assert_receive {:tag_request, "tag-object"}, 500
    assert %{"type" => "tag", "sha" => "a", "tag" => "nested"} = List.last(rows(path))
  end

  test "pending head finalizes failure and recovery on the same SHA across captures", %{path: path} do
    rollup = :atomics.new(1, [])

    request = fn request ->
      state = Enum.at(["PENDING", "FAILURE", "SUCCESS"], :atomics.get(rollup, 1))
      response([commit("a", 1, state)], [], request)
    end

    now = fn -> DateTime.add(~U[2026-10-09 00:00:10Z], :atomics.get(rollup, 1)) end
    worker = worker(path, request, now_fun: now)
    assert :ok = RepoTimeline.capture(worker)
    :atomics.put(rollup, 1, 1)
    assert :ok = RepoTimeline.capture(worker)
    assert boundaries(rows(path)) == [{"main_red_start", "a"}]
    GenServer.stop(worker)
    :atomics.put(rollup, 1, 2)
    restarted = worker(path, request, now_fun: now)
    assert :ok = RepoTimeline.capture(restarted)
    assert boundaries(rows(path)) == [{"main_red_start", "a"}, {"main_red_end", "a"}]
    observed = Enum.filter(rows(path), &(&1["source"] == "observation"))
    assert Enum.map(observed, & &1["ts"]) == ["2026-10-09T00:00:11Z", "2026-10-09T00:00:12Z"]
    assert [%{"rollup_state" => "PENDING"}] = Enum.filter(rows(path), &(&1["type"] == "commit"))
    contents = File.read!(path)
    assert :ok = RepoTimeline.capture(restarted)
    assert File.read!(path) == contents
  end

  test "a pending head finalizing with a newer success cannot close red before it starts", %{path: path} do
    capture = :atomics.new(1, [])

    request = fn request ->
      commits = if :atomics.get(capture, 1) == 0, do: [commit("a", 1, "PENDING")], else: [commit("b", 2, "SUCCESS"), commit("a", 1, "FAILURE")]
      response(commits, [], request)
    end

    worker = worker(path, request, now_fun: fn -> ~U[2026-10-09 00:00:03Z] end)
    assert :ok = RepoTimeline.capture(worker)
    :atomics.put(capture, 1, 1)
    assert :ok = RepoTimeline.capture(worker)
    interval = Enum.filter(rows(path), &(&1["type"] in ["main_red_start", "main_red_end"]))
    assert Enum.map(interval, & &1["ts"]) == ["2026-10-09T00:00:03Z", "2026-10-09T00:00:03Z"]
    assert Enum.map(interval, & &1["source"]) == ["observation", "observation"]
    contents = File.read!(path)
    assert :ok = RepoTimeline.capture(worker)
    assert File.read!(path) == contents
  end

  defp worker(path, request, extra \\ []) do
    opts = [name: nil, path: path, repo: "owner/repo", branch: "integration", token: "test", request_fun: request, enabled_fun: fn -> true end, boot_capture: false, interval_ms: 3_600_000]
    start_supervised!({RepoTimeline, Keyword.merge(opts, extra)}, id: make_ref())
  end

  defp response(commits, tags, request, history_page \\ {false, nil}, tags_page \\ {false, nil}) do
    assert request.caller == "analytics_repo_timeline"
    body = %{"data" => %{"repository" => %{"ref" => %{"target" => %{"history" => connection(commits, history_page)}}, "refs" => connection(tags, tags_page)}}}
    {:ok, %{status: 200, body: body, headers: %{}}}
  end

  defp connection(nodes, {more, cursor}), do: %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => more, "endCursor" => cursor}}
  defp timestamp(second), do: "2026-10-09T00:00:#{String.pad_leading(to_string(second), 2, "0")}Z"
  defp tag(name, sha, second), do: %{"name" => name, "target" => %{"__typename" => "Commit", "oid" => sha, "committedDate" => timestamp(second)}}

  defp commit(sha, second, rollup),
    do: %{
      "oid" => sha,
      "committedDate" => timestamp(second),
      "message" => "private prose",
      "messageHeadline" => "private headline",
      "associatedPullRequests" => %{"nodes" => []},
      "statusCheckRollup" => %{"state" => rollup}
    }

  defp rows(path), do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  defp boundaries(rows), do: rows |> Enum.filter(&String.starts_with?(&1["type"], "main_red")) |> Enum.map(&{&1["type"], &1["sha"]})
end
