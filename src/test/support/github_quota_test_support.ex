defmodule Aiur.GitHub.QuotaTestSupport do
  @moduledoc false

  import ExUnit.Callbacks

  alias Aiur.GitHub.Quota

  @now ~U[2026-08-09 21:00:00Z]
  @reset ~U[2026-08-09 22:00:00Z]

  def anonymous_request(path) do
    %{method: :get, url: "https://api.github.com#{path}", token: nil, anonymous: true}
  end

  def start_quota(opts \\ []) do
    # Request logging is disabled here unless a test opts in; otherwise the
    # resolved default path would point at this checkout's repo state and every
    # observe would write a stray file.
    start_supervised!({Quota, Keyword.merge([name: nil, clock: fn -> @now end, hold_dir: nil, request_log_path: nil], opts)})
  end

  def eventually(fun, attempts \\ 50)
  def eventually(_fun, 0), do: false

  def eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  def request(method, path) do
    %{method: method, url: "https://api.github.com#{path}", token: "secret"}
  end

  def graphql_request(query, variables) do
    %{
      method: :post,
      url: "https://api.github.com/graphql",
      token: "secret",
      body: %{"query" => query, "variables" => variables}
    }
  end

  # GitHub answers a secondary/abuse limit with a 403 whose body carries the
  # rate-limit wording, a still-healthy `x-ratelimit-remaining`, and usually a
  # `Retry-After` in seconds.
  def secondary_response(resource, remaining, retry_after) do
    headers =
      [
        {"x-ratelimit-resource", resource},
        {"x-ratelimit-limit", "5000"},
        {"x-ratelimit-remaining", Integer.to_string(remaining)},
        {"x-ratelimit-reset", Integer.to_string(DateTime.to_unix(@reset))}
      ] ++ if(retry_after, do: [{"retry-after", Integer.to_string(retry_after)}], else: [])

    {:ok,
     %{
       status: 403,
       headers: headers,
       body: %{"message" => "You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}
     }}
  end

  def generic_rate_limit_response(resource, remaining) do
    {:ok,
     %{
       status: 403,
       headers: [
         {"x-ratelimit-resource", resource},
         {"x-ratelimit-limit", "5000"},
         {"x-ratelimit-remaining", Integer.to_string(remaining)},
         {"x-ratelimit-reset", Integer.to_string(DateTime.to_unix(@reset))}
       ],
       body: %{"message" => "API rate limit exceeded"}
     }}
  end

  # A GraphQL response that reports what the query spent, the way the Build
  # Order catalog query does since `rateLimit { cost }` was added to it (#1766).
  def graphql_response(remaining, cost) do
    {:ok, response} = response("graphql", 5000, remaining)

    {:ok, %{response | body: %{"data" => %{"rateLimit" => %{"cost" => cost, "remaining" => remaining, "limit" => 5000}}}}}
  end

  # The block the transport's injected `rateLimit { limit cost remaining
  # resetAt }` selection brings back on every instrumented query.
  def rate_limit_block(remaining) do
    %{
      "rateLimit" => %{
        "cost" => 1,
        "limit" => 5000,
        "remaining" => remaining,
        "resetAt" => DateTime.to_iso8601(@reset)
      }
    }
  end

  def reported_graphql_response(remaining) do
    {:ok, %{status: 200, headers: [], body: %{"data" => rate_limit_block(remaining)}}}
  end

  def not_modified(resource, remaining) do
    {:ok, response} = response(resource, 5000, remaining)
    {:ok, %{response | status: 304}}
  end

  def drop_cost_fields(attribution), do: Enum.map(attribution, &Map.drop(&1, [:cost, :costs, :estimated?]))

  def response(resource, limit, remaining, reset \\ @reset) do
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
end
