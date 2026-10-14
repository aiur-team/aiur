defmodule Aiur.BuildOrder.TicketDetailLinkedPrsTest do
  use ExUnit.Case, async: false

  alias Aiur.{BuildOrder.TicketDetail, TrackerIdentity}
  alias Aiur.BuildOrder.TicketDetail.{Destinations, Failure, PullRequestDestination, Snapshot}
  alias Aiur.GitHub.{ReadCache, ResourceStore}

  # `Aiur.GitHub.ResourceStore` is global by design — the whole point is that a
  # resource fetched by one reader satisfies every other — so without this a body
  # stored for issue 42 by one case is served to the next case instead of its own
  # stub, and the stub it injected is never called. The read cache is the same
  # shared app child and now caches `/issues/{n}` reads (`:issue`, #2352), so a
  # transport-backed case (e.g. the oversized-response abort) must not be served
  # a body an earlier case deposited.
  setup do
    ResourceStore.reset()
    ReadCache.reset()
    :ok
  end

  @configured {"owner", "repo"}

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:req)
    :ok
  end

  test "loads a complete bounded snapshot for the configured identity" do
    identity = identity(42, "I42")
    observed_at = ~U[2026-07-14 09:00:00Z]

    assert {:ok, %Snapshot{} = snapshot} =
             fetch(identity,
               configured_repo: @configured,
               now: observed_at,
               request_fun: fn request ->
                 assert request.url == "https://api.github.com/repos/owner/repo/issues/42"
                 {:ok, %{status: 200, body: issue(42, "I42")}}
               end
             )

    assert snapshot.identity == identity
    assert snapshot.title == "Configured ticket"
    assert snapshot.description == "A bounded description"
    assert snapshot.lifecycle.state == :open
    assert snapshot.url == "https://github.com/owner/repo/issues/42"

    assert %Destinations{
             issue: %{url: "https://github.com/owner/repo/issues/42"},
             pull_requests: [],
             primary_pull_request: :not_linked,
             pull_requests_truncated?: false
           } = snapshot.destinations

    assert snapshot.created_at == ~U[2026-07-01 10:00:00Z]
    assert snapshot.updated_at == ~U[2026-07-02 11:00:00Z]
    assert snapshot.observed_at == observed_at
  end

  test "loads bounded linked pull-request destinations through authenticated relationship data" do
    identity = identity(42, "I42")

    request_fun = fn
      %{method: :get, url: "https://api.github.com/repos/owner/repo/issues/42"} = request ->
        assert request.max_response_bytes == 65_536
        {:ok, %{status: 200, body: issue(42, "I42")}}

      %{
        method: :post,
        url: "https://api.github.com/graphql",
        body: %{"query" => query, "variables" => variables}
      } = request ->
        assert query =~ "closedByPullRequestsReferences"
        assert query =~ "includeClosedPrs: true"
        assert query =~ "orderByState: true"
        assert variables == %{"limit" => 20, "number" => 42, "owner" => "owner", "repository" => "repo"}
        assert request.max_response_bytes == 32_768

        {:ok,
         %{
           status: 200,
           body:
             relationship_response(
               "I42",
               [
                 linked_pull_request(80, "MERGED", false, "2026-07-14T12:00:00Z"),
                 linked_pull_request(81, "OPEN", false, "2026-07-13T12:00:00Z"),
                 linked_pull_request(82, "OPEN", true, "2026-07-12T12:00:00Z")
               ],
               true
             )
         }}
    end

    assert {:ok,
            %Snapshot{
              destinations: %Destinations{
                issue: %{url: "https://github.com/owner/repo/issues/42"},
                pull_requests: [
                  %PullRequestDestination{number: 82, state: :open, draft?: true},
                  %PullRequestDestination{number: 81, state: :open, draft?: false},
                  %PullRequestDestination{number: 80, state: :merged, draft?: false}
                ],
                primary_pull_request: %PullRequestDestination{
                  number: 82,
                  url: "https://github.com/owner/repo/pull/82"
                },
                pull_requests_truncated?: true
              }
            }} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: request_fun
             )
  end

  test "preserves typed GraphQL relationship failures" do
    identity = identity(42, "I42")

    for %{error: graphql_error, headers: headers, failure: expected_failure} <- [
          %{
            error: %{"type" => "RATE_LIMITED", "message" => "rate limit exceeded"},
            headers: [{"retry-after", "17"}],
            failure: %Failure{kind: :rate_limited, retry_after: 17}
          },
          %{
            error: %{"type" => "FORBIDDEN", "message" => "resource not accessible"},
            headers: [],
            failure: %Failure{kind: :permission}
          }
        ] do
      request_fun = fn
        %{method: :get} ->
          {:ok, %{status: 200, body: issue(42, "I42")}}

        %{method: :post} ->
          {:ok,
           %{
             status: 200,
             headers: headers,
             body: %{"errors" => [graphql_error]}
           }}
      end

      assert {:error, ^expected_failure} =
               TicketDetail.fetch(identity,
                 configured_repo: @configured,
                 request_fun: request_fun
               )
    end
  end

  test "rejects foreign or malformed linked pull-request destinations" do
    identity = identity(42, "I42")

    for invalid <- [
          normalized_pull_request(80, "MERGED", false, "2026-07-14T12:00:00Z")
          |> Map.put(:url, "https://github.com/other/repo/pull/80"),
          normalized_pull_request(80, "MERGED", false, "2026-07-14T12:00:00Z")
          |> Map.put(:url, "https://github.com/owner/repo/issues/80"),
          normalized_pull_request(80, "INVENTED", false, "2026-07-14T12:00:00Z")
        ] do
      assert {:error, %Failure{kind: :validation}} =
               fetch(identity,
                 configured_repo: @configured,
                 relationship_reader: fn _identity, _repository ->
                   {:ok, %{nodes: [invalid], truncated?: false}}
                 end,
                 request_fun: fn _request -> {:ok, %{status: 200, body: issue(42, "I42")}} end
               )
    end
  end

  test "selects the newest terminal pull request when no active link exists" do
    identity = identity(42, "I42")

    assert {:ok,
            %Snapshot{
              destinations: %Destinations{
                primary_pull_request: %PullRequestDestination{number: 91, state: :merged}
              }
            }} =
             fetch(identity,
               configured_repo: @configured,
               relationship_reader: fn _identity, _repository ->
                 {:ok,
                  %{
                    nodes: [
                      normalized_pull_request(90, "CLOSED", true, "2026-07-12T12:00:00Z"),
                      normalized_pull_request(91, "MERGED", false, "2026-07-14T12:00:00Z")
                    ],
                    truncated?: false
                  }}
               end,
               request_fun: fn _request -> {:ok, %{status: 200, body: issue(42, "I42")}} end
             )
  end

  test "rejects an over-bound or duplicate linked pull-request set" do
    identity = identity(42, "I42")
    destination = normalized_pull_request(80, "OPEN", false, "2026-07-14T12:00:00Z")

    for nodes <- [
          List.duplicate(destination, 21),
          [destination, destination]
        ] do
      assert {:error, %Failure{kind: :validation}} =
               fetch(identity,
                 configured_repo: @configured,
                 relationship_reader: fn _identity, _repository ->
                   {:ok, %{nodes: nodes, truncated?: false}}
                 end,
                 request_fun: fn _request -> {:ok, %{status: 200, body: issue(42, "I42")}} end
               )
    end
  end

  defp relationship_response(provider_id, nodes, truncated?) do
    %{
      "data" => %{
        "repository" => %{
          "issue" => %{
            "id" => provider_id,
            "closedByPullRequestsReferences" => %{
              "nodes" => nodes,
              "pageInfo" => %{"hasNextPage" => truncated?}
            }
          }
        }
      }
    }
  end

  defp linked_pull_request(number, state, draft?, updated_at) do
    %{
      "number" => number,
      "url" => "https://github.com/owner/repo/pull/#{number}",
      "state" => state,
      "isDraft" => draft?,
      "updatedAt" => updated_at
    }
  end

  defp normalized_pull_request(number, state, draft?, updated_at) do
    %{
      number: number,
      url: "https://github.com/owner/repo/pull/#{number}",
      state: state,
      draft?: draft?,
      updated_at: updated_at
    }
  end

  defp fetch(identity, opts) do
    opts =
      opts
      |> Keyword.put_new(:relationship_reader, fn _identity, _repository ->
        {:ok, %{nodes: [], truncated?: false}}
      end)
      # These cases are about how one response body normalizes, and several of
      # them stub a different body for the *same* issue in the same test. Reads
      # now resolve against the shared store first, so without this the second
      # stub is never reached and the case silently asserts against the first
      # body. `revalidate: true` is the caller saying "actually read it", which
      # is what a normalization test means.
      |> Keyword.put_new(:revalidate, true)

    TicketDetail.fetch(identity, opts)
  end

  defp identity(number, node_id, repository \\ @configured) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => node_id, "number" => number},
        repository,
        repository
      )

    identity
  end

  defp issue(number, node_id) do
    %{
      "node_id" => node_id,
      "number" => number,
      "title" => "Configured ticket",
      "body" => "A bounded description",
      "html_url" => "https://github.com/owner/repo/issues/#{number}",
      "repository_url" => "https://api.github.com/repos/owner/repo",
      "state" => "open",
      "state_reason" => nil,
      "created_at" => "2026-07-01T10:00:00Z",
      "updated_at" => "2026-07-02T11:00:00Z"
    }
  end
end
