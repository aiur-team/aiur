defmodule Aiur.MainWatch.FixerGitHubTest do
  use Aiur.TestSupport
  alias Aiur.GitHub.{Config, MainFixer, ResourceStore}
  alias Aiur.MainWatch.FixerGitHub
  @marker "<!-- aiur:main-watch signature=#{String.duplicate("b", 64)} sha=#{String.duplicate("a", 40)} -->"

  test "open issues include earlier main-watch comments and exclude PRs and unmarked issues" do
    parent = self()

    request = fn call ->
      send(parent, {:request, call})

      if String.contains?(call.url, "/comments") do
        {:ok, %{status: 200, body: [%{"body" => @marker <> "\nnew failing test"}, %{"body" => "human discussion"}]}}
      else
        {:ok, %{status: 200, body: [%{"number" => 1, "body" => @marker, "comments" => 1}, %{"number" => 2, "body" => "unmarked"}, %{"number" => 3, "pull_request" => %{}}]}}
      end
    end

    assert {:ok, [issue]} = FixerGitHub.open("main-fix", request_fun: request)
    assert issue["number"] == 1
    assert MainFixer.marker(issue["body"]) != nil
    assert issue["body"] =~ "new failing test"
    refute issue["body"] =~ "human discussion"
    assert_received {:request, %{caller: "main_fixer_open_issues"}}
    assert_received {:request, %{url: url}}
    assert url =~ "/issues/1/comments"
  end

  test "creation ensures labels then writes through the created issue" do
    parent = self()
    labels = ["agent:todo", "priority:1", "complexity:1", "main-fix"]

    request = fn call ->
      send(parent, {:request, call})
      body = if String.ends_with?(call.url, "/labels"), do: call.body, else: Map.put(call.body, "number", 7)
      {:ok, %{status: 201, body: body}}
    end

    assert {:ok, %{"number" => 7, "body" => @marker}} = FixerGitHub.create(%{"body" => @marker, "labels" => labels}, request_fun: request)

    for label <- labels do
      assert_received {:request, %{method: :post, body: %{"name" => ^label}}}
    end

    assert_received {:request, %{method: :post, caller: "main_fixer_create", body: %{"labels" => ^labels}}}
    key = ResourceStore.key_for_repo(:issue, Config.repo(), "7")
    assert {:ok, %{data: %{"number" => 7, "body" => @marker}}} = ResourceStore.fetch(key)
  end

  test "transport, status and label errors propagate instead of pretending to file" do
    assert {:error, :offline} = FixerGitHub.open("main-fix", request_fun: fn _ -> {:error, :offline} end)
    assert {:error, _reason} = FixerGitHub.open("main-fix", request_fun: fn _ -> {:ok, %{status: 503}} end)
    assert {:error, :offline} = FixerGitHub.create(%{"labels" => []}, request_fun: fn _ -> {:error, :offline} end)
    assert {:error, _reason} = FixerGitHub.create(%{"labels" => ["main-fix"]}, request_fun: fn _ -> {:ok, %{status: 422}} end)
  end
end
