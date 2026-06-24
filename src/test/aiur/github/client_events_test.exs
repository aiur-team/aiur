defmodule Aiur.GitHub.ClientEventsTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Client
  alias Aiur.Workflow

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn -> restore_env("GITHUB_TOKEN", prev_token) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur"
    )

    :ok
  end

  describe "fetch_repo_events/1" do
    test "200 with events returns parsed list + ETag + poll interval" do
      events = [
        %{"id" => "1", "type" => "PushEvent"},
        %{"id" => "2", "type" => "IssuesEvent"}
      ]

      stub = fn _req ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("abc")}, {"X-Poll-Interval", "30"}],
           body: events
         }}
      end

      assert {:ok, {:events, ^events, ~s("abc"), 30}} =
               Client.fetch_repo_events(request_fun: stub)
    end

    test "passes page and per_page query parameters" do
      stub = fn req ->
        uri = URI.parse(req.url)

        assert uri.path == "/repos/owner/repo/events"
        assert URI.decode_query(uri.query) == %{"page" => "2", "per_page" => "10"}

        {:ok, %{status: 200, headers: [], body: []}}
      end

      assert {:ok, {:events, [], nil, 60}} =
               Client.fetch_repo_events(request_fun: stub, page: 2, per_page: 10)
    end

    test "304 returns not_modified with cached etag + poll interval" do
      stub = fn %{etag: etag} ->
        assert etag == ~s("abc")

        {:ok,
         %{
           status: 304,
           headers: [{"ETag", ~s("abc")}, {"X-Poll-Interval", "60"}],
           body: ""
         }}
      end

      assert {:ok, {:not_modified, ~s("abc"), 60}} =
               Client.fetch_repo_events(request_fun: stub, etag: ~s("abc"))
    end

    test "missing X-Poll-Interval header defaults to 60" do
      stub = fn _req ->
        {:ok, %{status: 200, headers: [], body: []}}
      end

      assert {:ok, {:events, [], nil, 60}} =
               Client.fetch_repo_events(request_fun: stub)
    end

    test "non-200/304 status returns error" do
      stub = fn _req -> {:ok, %{status: 500, headers: [], body: ""}} end
      assert {:error, {:github_api_status, 500}} = Client.fetch_repo_events(request_fun: stub)
    end

    test "transport error returns wrapped error" do
      stub = fn _req -> {:error, :timeout} end
      assert {:error, {:github_api_request, :timeout}} = Client.fetch_repo_events(request_fun: stub)
    end
  end

  describe "fetch_blocked_by/2 and fetch_blocking/2" do
    test "200 returns list of issue maps" do
      issues = [%{"id" => 1001, "number" => 42}]
      stub = fn _req -> {:ok, %{status: 200, headers: [], body: issues}} end

      assert {:ok, ^issues} = Client.fetch_blocked_by(7, request_fun: stub)
      assert {:ok, ^issues} = Client.fetch_blocking(7, request_fun: stub)
    end

    test "uses 2026-03-10 API version header" do
      stub = fn req ->
        assert req.api_version == "2026-03-10"
        {:ok, %{status: 200, headers: [], body: []}}
      end

      Client.fetch_blocked_by(7, request_fun: stub)
    end

    test "404 returns error tuple" do
      stub = fn _req -> {:ok, %{status: 404, headers: [], body: ""}} end
      assert {:error, {:github_api_status, 404}} = Client.fetch_blocked_by(7, request_fun: stub)
    end
  end

  describe "add_dependency/3 and remove_dependency/3" do
    test "add posts issue_id in body" do
      stub = fn %{method: :post, body: %{"issue_id" => 99}} ->
        {:ok, %{status: 201, headers: [], body: %{"id" => 1001}}}
      end

      assert {:ok, %{"id" => 1001}} = Client.add_dependency(42, 99, request_fun: stub)
    end

    test "remove issues DELETE" do
      stub = fn %{method: :delete} ->
        {:ok, %{status: 200, headers: [], body: %{"id" => 1001}}}
      end

      assert {:ok, %{"id" => 1001}} = Client.remove_dependency(42, 99, request_fun: stub)
    end

    test "422 returns error (cycle detected by GitHub)" do
      stub = fn _req -> {:ok, %{status: 422, headers: [], body: %{}}} end
      assert {:error, {:github_api_status, 422}} = Client.add_dependency(42, 99, request_fun: stub)
    end
  end
end
