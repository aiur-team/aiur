defmodule Aiur.GitHub.RequestLogTest do
  @moduledoc """
  The durable request log writes one TSV row per observed request, with a
  closed-vocabulary route shape and a `billable` flag that the reconciliation
  criterion sums over.

  The lead test is the mutation-checked integration one: a real `Quota` is
  started with an explicit log path, two requests are observed through the
  public path, the `:delayed_write` buffer is flushed, and two rows must be on
  disk. Delete the `log_request` call in `Quota` and it fails — the test does
  not write the file itself.
  """

  use Aiur.TestSupport

  alias Aiur.GitHub.{Quota, RequestLog, RouteShape}

  @now ~U[2026-08-09 21:00:00Z]

  describe "integration with Quota" do
    test "observing requests writes one TSV row each through the public path" do
      path = unique_log_path()

      quota = start_quota(request_log_path: path)

      Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 3750))
      Quota.observe(quota, graphql_request("query A { viewer { login } }", %{}), response("graphql", 5000, 4400))

      Quota.flush_request_log(quota)

      lines = File.read!(path) |> String.split("\n", trim: true)
      assert length(lines) == 2

      [core_row, graphql_row] = lines
      core_cells = String.split(core_row, "\t")
      graphql_cells = String.split(graphql_row, "\t")

      # timestamp identity pool route_shape caller disposition status billable points
      assert length(core_cells) == 9
      assert Enum.at(core_cells, 0) == Integer.to_string(DateTime.to_unix(@now))
      assert Enum.at(core_cells, 2) == "core"
      assert Enum.at(core_cells, 3) in RouteShape.known_shapes()
      assert Enum.at(core_cells, 5) == "refused:unclassified"
      assert Enum.at(core_cells, 6) == "200"
      assert Enum.at(core_cells, 7) == "1"
      assert Enum.at(core_cells, 8) == "1"

      assert Enum.at(graphql_cells, 2) == "graphql"
      assert Enum.at(graphql_cells, 3) == "graphql"
    end
  end

  describe "billable" do
    test "a 304 costs nothing and is not billable" do
      path = unique_log_path()
      quota = start_quota(request_log_path: path)

      Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), not_modified("core", 3750))
      Quota.flush_request_log(quota)

      cells = File.read!(path) |> String.split("\n", trim: true) |> hd() |> String.split("\t")

      # status 304 → billable 0, points 0
      assert Enum.at(cells, 6) == "304"
      assert Enum.at(cells, 7) == "0"
      assert Enum.at(cells, 8) == "0"
    end

    test "a request that never got a response is not billable" do
      path = unique_log_path()
      quota = start_quota(request_log_path: path)

      Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), {:error, :fetch_deadline_exceeded})
      Quota.flush_request_log(quota)

      cells = File.read!(path) |> String.split("\n", trim: true) |> hd() |> String.split("\t")

      assert Enum.at(cells, 6) == ""
      assert Enum.at(cells, 7) == "0"
    end

    test "a GraphQL response reports the points it billed" do
      path = unique_log_path()
      quota = start_quota(request_log_path: path)

      Quota.observe(quota, graphql_request("query A { viewer { login } }", %{}), graphql_response(4400, 7))
      Quota.flush_request_log(quota)

      cells = File.read!(path) |> String.split("\n", trim: true) |> hd() |> String.split("\t")

      assert Enum.at(cells, 2) == "graphql"
      assert Enum.at(cells, 7) == "1"
      assert Enum.at(cells, 8) == "7"
    end
  end

  describe "route shape vocabulary" do
    test "the route-shape column is always one of the known constants" do
      path = unique_log_path()
      quota = start_quota(request_log_path: path)

      hostile = "https://api.github.com/repos/o/r/issues/1?access_token=ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

      Quota.observe(quota, request(:get, hostile), response("core", 5000, 3750))
      Quota.flush_request_log(quota)

      cells = File.read!(path) |> String.split("\n", trim: true) |> hd() |> String.split("\t")

      shape = Enum.at(cells, 3)
      assert shape in RouteShape.known_shapes()
      refute String.contains?(shape, "ghp_")
    end
  end

  describe "path resolution" do
    test "the run default is under the session log directory, disabled in test env" do
      assert RequestLog.default_path() == nil
      assert RequestLog.file_name() == "github-requests.tsv"
    end

    test "append/4 writes a row to an explicit path" do
      path = unique_log_path()
      :ok = RequestLog.append(request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 3750), @now, path: path)

      assert File.read!(path) |> String.split("\n", trim: true) |> length() == 1
    end
  end

  defp start_quota(opts) do
    start_supervised!({Quota, Keyword.merge([name: nil, clock: fn -> @now end, hold_dir: nil], opts)})
  end

  defp unique_log_path do
    path = Path.join(System.tmp_dir!(), "github-requests-#{System.unique_integer([:positive])}.tsv")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp request(method, url_or_path) do
    url =
      if String.starts_with?(url_or_path, "http"), do: url_or_path, else: "https://api.github.com#{url_or_path}"

    %{method: method, url: url, token: "secret"}
  end

  defp graphql_request(query, variables) do
    %{
      method: :post,
      url: "https://api.github.com/graphql",
      token: "secret",
      body: %{"query" => query, "variables" => variables}
    }
  end

  defp response(resource, limit, remaining, reset \\ DateTime.add(@now, 3600, :second)) do
    {:ok,
     %{
       status: 200,
       headers: [
         {"x-ratelimit-resource", resource},
         {"x-ratelimit-limit", Integer.to_string(limit)},
         {"x-ratelimit-remaining", Integer.to_string(remaining)},
         {"x-ratelimit-reset", Integer.to_string(DateTime.to_unix(reset))}
       ],
       body: %{}
     }}
  end

  defp not_modified(resource, remaining) do
    {:ok, response} = response(resource, 5000, remaining)
    {:ok, %{response | status: 304}}
  end

  defp graphql_response(remaining, cost) do
    {:ok, response} = response("graphql", 5000, remaining)

    {:ok,
     %{
       response
       | body: %{"data" => %{"rateLimit" => %{"cost" => cost, "remaining" => remaining, "limit" => 5000}}}
     }}
  end
end
