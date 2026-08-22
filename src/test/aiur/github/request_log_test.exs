defmodule Aiur.GitHub.RequestLogTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{Budget, Quota, RequestLog}

  @now ~U[2026-08-09 21:00:00Z]
  @reset ~U[2026-08-09 22:00:00Z]

  defp tmp_path do
    path = Path.join(System.tmp_dir!(), "aiur-request-log-#{System.unique_integer([:positive])}.tsv")
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp request(method, path) do
    %{method: method, url: "https://api.github.com#{path}", token: "secret-token"}
  end

  defp graphql_request(query, variables) do
    %{method: :post, url: "https://api.github.com/graphql", token: "secret-token", body: %{"query" => query, "variables" => variables}}
  end

  defp response(resource, limit, remaining, reset \\ @reset) do
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

  defp columns(line), do: String.split(line, "\t")

  test "writes one row per request with the full record for a REST read" do
    path = tmp_path()

    :ok =
      RequestLog.append(
        request(:get, "/repos/owner/repo/issues/1670"),
        response("core", 5000, 3750),
        @now,
        path: path
      )

    [line] = File.read!(path) |> String.split("\n", trim: true)
    ts = Integer.to_string(DateTime.to_unix(@now))
    pid = :os.getpid() |> List.to_integer() |> Integer.to_string()

    assert [^ts, ^pid, "ticket:1670", caller, "get", "api.github.com", "/repos/owner/repo/issues/1670", "200", "core", "read", "1", "reported", token_key] = columns(line)

    assert is_binary(caller) and caller != ""
    assert token_key == Budget.token_key("secret-token")
    refute line =~ "secret-token"
  end

  test "GraphQL requests record the operation name as caller and the reported cost" do
    path = tmp_path()
    response = {:ok, %{status: 200, headers: [], body: %{"data" => %{"rateLimit" => %{"cost" => 26, "remaining" => 4973, "limit" => 5000}}}}}

    :ok =
      RequestLog.append(
        graphql_request("query Catalog { repository { issues { nodes { id } } } }", %{"number" => 1790}),
        response,
        @now,
        path: path
      )

    [line] = File.read!(path) |> String.split("\n", trim: true)
    ts = Integer.to_string(DateTime.to_unix(@now))
    assert [^ts, _, "ticket:1790", "graphql:Catalog", "post", "api.github.com", "/graphql", "200", "graphql", "read", "26", "reported", _] = columns(line)
  end

  test "a not-modified response is recorded at zero cost" do
    path = tmp_path()

    :ok =
      RequestLog.append(
        request(:get, "/repos/owner/repo/issues/1670"),
        {:ok, %{status: 304, headers: [], body: %{}}},
        @now,
        path: path
      )

    [line] = File.read!(path) |> String.split("\n", trim: true)
    ts = Integer.to_string(DateTime.to_unix(@now))
    assert [^ts, _, "ticket:1670", _, "get", _, _, "304", "core", "read", "0", "reported", _] = columns(line)
  end

  test "a failed request is recorded with an error status and an assumed cost" do
    path = tmp_path()

    :ok =
      RequestLog.append(
        request(:get, "/repos/owner/repo/issues/1670"),
        {:error, :fetch_deadline_exceeded},
        @now,
        path: path
      )

    [line] = File.read!(path) |> String.split("\n", trim: true)
    ts = Integer.to_string(DateTime.to_unix(@now))
    assert [^ts, _, "ticket:1670", _, "get", _, _, "error", "core", "read", "1", "assumed", _] = columns(line)
  end

  test "rotates the active file and keeps the previous generations for retention" do
    path = tmp_path()
    # One row far past the rotation cap so the next append rotates immediately.
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, String.duplicate("x", 1_048_577) <> "\n")

    :ok = RequestLog.append(request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 3750), @now, path: path)

    assert File.exists?(path)
    assert File.exists?("#{path}.1")
  end

  test "is a no-op when no path can be resolved" do
    assert :ok = RequestLog.append(request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 3750), @now, path: nil)
  end

  # The acceptance criterion's mutation check (#2255): a GitHub request issued
  # through the real request path must ALWAYS produce a corresponding log row.
  # This test never writes the file itself — the row can only appear if
  # `Quota.handle_cast({:observe, ...})` calls `RequestLog.append`. Delete that
  # call and this fails: a request with no log record.
  test "a GitHub request observed by Quota always lands a request-log row" do
    path = tmp_path()
    quota = start_quota(request_log_path: path)

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 3750))
    Quota.observe(quota, graphql_request("query Ticket { repository { issue(number: 1790) { id } } }", %{"number" => 1790}), graphql_response())
    # The call settles the two casts above (they run before any later message).
    _snapshot = Quota.snapshot(quota)

    rows = File.read!(path) |> String.split("\n", trim: true)
    assert length(rows) == 2

    ts = Integer.to_string(DateTime.to_unix(@now))

    assert Enum.any?(rows, fn row ->
             match?([^ts, _, "ticket:1670", _, "get", _, "/repos/owner/repo/issues/1670", "200", "core", "read", "1", "reported", _], columns(row))
           end)

    assert Enum.any?(rows, fn row ->
             match?([^ts, _, "ticket:1790", "graphql:Ticket", "post", _, "/graphql", "200", "graphql", "read", "1", "reported", _], columns(row))
           end)
  end

  defp graphql_response do
    {:ok, %{status: 200, headers: [], body: %{"data" => %{"rateLimit" => %{"cost" => 1, "remaining" => 4973, "limit" => 5000}}}}}
  end

  defp start_quota(opts) do
    start_supervised!({Quota, Keyword.merge([name: nil, clock: fn -> @now end, hold_dir: nil], opts)})
  end
end
