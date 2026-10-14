defmodule Aiur.BuildOrder.TicketDetailProviderFailureTest do
  use ExUnit.Case, async: false

  alias Aiur.{BuildOrder.TicketDetail, TrackerIdentity}
  alias Aiur.BuildOrder.TicketDetail.Failure
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
  @token_cache_key {Aiur.GitHub.Config, :resolved_token}
  @transport_test_options_key :github_transport_test_options

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:req)
    :ok
  end

  test "maps missing production GitHub credentials to an auth failure" do
    identity = identity(42, "I42")
    previous_token = System.get_env("GITHUB_TOKEN")
    previous_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.delete_env("GITHUB_TOKEN")

    on_exit(fn ->
      if previous_token, do: System.put_env("GITHUB_TOKEN", previous_token)

      case previous_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    assert {:error, %Failure{kind: :auth}} =
             fetch(identity, configured_repo: @configured)
  end

  test "aborts an oversized GitHub response before JSON normalization" do
    identity = identity(42, "I42")
    previous_token = System.get_env("GITHUB_TOKEN")
    previous_cached_token = :persistent_term.get(@token_cache_key, :unset)
    previous_request_options = Application.get_env(:aiur, @transport_test_options_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "configured-detail-token")
    Application.put_env(:aiur, @transport_test_options_key, plug: {Req.Test, {__MODULE__, :oversized}})

    on_exit(fn ->
      if previous_token, do: System.put_env("GITHUB_TOKEN", previous_token), else: System.delete_env("GITHUB_TOKEN")

      case previous_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end

      case previous_request_options do
        :unset -> Application.delete_env(:aiur, @transport_test_options_key)
        options -> Application.put_env(:aiur, @transport_test_options_key, options)
      end
    end)

    Req.Test.stub({__MODULE__, :oversized}, fn conn ->
      body = issue(42, "I42") |> Map.put("body", String.duplicate("x", 70_000)) |> Jason.encode!()

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)

    assert {:error, %Failure{kind: :schema}} =
             fetch(identity, configured_repo: @configured)
  end

  test "maps not-found and rate-limit errors without response content" do
    identity = identity(42, "I42")

    assert {:error, %Failure{kind: :not_found}} =
             fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 404, body: %{"message" => "private /tmp/response"}}} end
             )

    assert {:error, %Failure{kind: :rate_limited, retry_after: 30}} =
             fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 429, headers: [{"retry-after", "30"}], body: %{"message" => "limit"}}} end
             )
  end

  test "clamps provider retry hints to the documented public bound" do
    identity = identity(42, "I42")
    maximum = TicketDetail.max_retry_after_seconds()

    for {retry_after, expected} <- [{maximum, maximum}, {maximum + 1, maximum}, {9_999_999, maximum}] do
      assert {:error, %Failure{kind: :rate_limited, retry_after: ^expected}} =
               fetch(identity,
                 configured_repo: @configured,
                 request_fun: fn _request ->
                   {:ok, %{status: 429, headers: [{"retry-after", Integer.to_string(retry_after)}], body: %{"message" => "limit"}}}
                 end
               )
    end
  end

  test "preserves structured provider failures without provider payloads" do
    identity = identity(42, "I42")

    for {response, expected_failure} <- [
          {{:ok, %{status: 401, body: %{"message" => "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"}}}, :auth},
          {{:ok, %{status: 403, body: %{"message" => "private /tmp/response"}}}, :permission},
          {{:error, :timeout}, :timeout},
          {{:error, :nxdomain}, :transport},
          {{:ok, %{status: 500, body: %{"message" => "private /tmp/response"}}}, :transport}
        ] do
      assert {:error, %Failure{kind: ^expected_failure} = failure} =
               fetch(identity,
                 configured_repo: @configured,
                 request_fun: fn _request -> response end
               )

      assert Map.keys(failure) == [:__struct__, :kind, :retry_after]
    end
  end

  test "maps a successful but non-map provider response to schema failure" do
    identity = identity(42, "I42")

    assert {:error, %Failure{kind: :schema}} =
             fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: ["not", "an", "issue"]}} end
             )
  end

  test "rejects oversized provider text rather than publishing it" do
    identity = identity(42, "I42")

    assert {:error, %Failure{kind: :validation}} =
             fetch(identity,
               configured_repo: @configured,
               max_description_bytes: 8,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", "too long!")}} end
             )
  end

  test "does not let an adapter option raise the hard description bound" do
    identity = identity(42, "I42")

    assert {:error, %Failure{kind: :validation}} =
             fetch(identity,
               configured_repo: @configured,
               max_description_bytes: 1_000_000,
               request_fun: fn _request ->
                 {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", String.duplicate("a", 16_385))}}
               end
             )
  end

  test "rejects malformed or oversized title and canonical URL values" do
    identity = identity(42, "I42")

    for issue <- [
          Map.put(issue(42, "I42"), "title", String.duplicate("a", 513)),
          Map.put(issue(42, "I42"), "title", 42),
          Map.put(issue(42, "I42"), "html_url", "https://github.com/other/repo/issues/42"),
          Map.put(issue(42, "I42"), "html_url", "https://token@github.com/owner/repo/issues/42"),
          Map.put(issue(42, "I42"), "html_url", "https://github.com/owner/repo/issues/42?private=/tmp/path")
        ] do
      assert {:error, %Failure{kind: :validation}} =
               fetch(identity,
                 configured_repo: @configured,
                 request_fun: fn _request -> {:ok, %{status: 200, body: issue}} end
               )
    end
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
