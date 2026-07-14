defmodule Aiur.BuildOrder.TicketDetailTest do
  use ExUnit.Case, async: false

  alias Aiur.{BuildOrder.TicketDetail, TrackerIdentity}
  alias Aiur.BuildOrder.TicketDetail.{Failure, Snapshot}

  @configured {"owner", "repo"}
  @token_cache_key {Aiur.GitHub.Config, :resolved_token}
  @transport_test_options_key :github_transport_test_options

  test "loads a complete bounded snapshot for the configured identity" do
    identity = identity(42, "I42")
    observed_at = ~U[2026-07-14 09:00:00Z]

    assert {:ok, %Snapshot{} = snapshot} =
             TicketDetail.fetch(identity,
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
    assert snapshot.created_at == ~U[2026-07-01 10:00:00Z]
    assert snapshot.updated_at == ~U[2026-07-02 11:00:00Z]
    assert snapshot.observed_at == observed_at
  end

  test "uses configured credentials through the default request path" do
    identity = identity(42, "I42")
    previous_token = System.get_env("GITHUB_TOKEN")
    previous_cached_token = :persistent_term.get(@token_cache_key, :unset)
    previous_request_options = Application.get_env(:aiur, @transport_test_options_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "configured-detail-token")
    Application.put_env(:aiur, @transport_test_options_key, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      case previous_token do
        nil -> System.delete_env("GITHUB_TOKEN")
        token -> System.put_env("GITHUB_TOKEN", token)
      end

      case previous_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end

      case previous_request_options do
        :unset -> Application.delete_env(:aiur, @transport_test_options_key)
        options -> Application.put_env(:aiur, @transport_test_options_key, options)
      end
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/owner/repo/issues/42"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer configured-detail-token"]
      Req.Test.json(conn, issue(42, "I42"))
    end)

    assert {:ok, %Snapshot{title: "Configured ticket"}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured
             )
  end

  test "rejects another repository before the request function is invoked" do
    foreign = identity(42, "Foreign42", {"other", "repo"})

    assert {:error, %Failure{kind: :nonfetchable_repository}} =
             TicketDetail.fetch(foreign,
               configured_repo: @configured,
               request_fun: fn _request -> flunk("transport must not be called") end
             )
  end

  test "rejects an unjoinable identity before transport work" do
    identity = TrackerIdentity.unjoinable(:legacy, owner: "owner", repository: "repo", identifier: 42)

    assert {:error, %Failure{kind: :nonfetchable_repository}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> flunk("transport must not be called") end
             )
  end

  test "does not accept same-number data for a different provider node" do
    identity = identity(42, "I42")

    assert {:error, %Failure{kind: :provider_identity_mismatch}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: issue(42, "OtherNode")}} end
             )
  end

  test "does not accept a response repository or lifecycle that disagrees with a complete snapshot" do
    identity = identity(42, "I42")

    for {issue, expected_failure} <- [
          {Map.put(issue(42, "I42"), "repository_url", "https://api.github.com/repos/other/repo"), :provider_identity_mismatch},
          {Map.put(issue(42, "I42"), "state", "invented"), :validation}
        ] do
      assert {:error, %Failure{kind: ^expected_failure}} =
               TicketDetail.fetch(identity,
                 configured_repo: @configured,
                 request_fun: fn _request -> {:ok, %{status: 200, body: issue}} end
               )
    end
  end

  test "rejects pull-request payloads from the issue endpoint" do
    identity = identity(42, "I42")

    assert {:error, %Failure{kind: :schema}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "pull_request", %{})}} end
             )
  end

  test "keeps an absent body distinct from a malformed description" do
    identity = identity(42, "I42")

    assert {:ok, %Snapshot{description: nil}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", nil)}} end
             )

    assert {:error, %Failure{kind: :validation}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", 42)}} end
             )
  end

  test "redacts credentials and local paths before detail reaches a snapshot" do
    identity = identity(42, "I42")

    body = "token ghp_abcdefghijklmnopqrstuvwxyz0123456789 and /home/alice/private.txt"

    assert {:ok, %Snapshot{description: description}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", body)}} end
             )

    assert description =~ "[REDACTED:ghp]"
    assert description =~ "[REDACTED:local_path]"
    refute description =~ "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    refute description =~ "/home/alice/private.txt"
  end

  test "redacts sensitive headers and generic credentials before snapshot storage" do
    identity = identity(42, "I42")

    body =
      "Authorization: Bearer not-a-known-prefix-secret\n" <>
        "X-Api-Key: unrecognized-api-key\n" <>
        "inline Basic dXNlcjpwYXNzd29yZA=="

    assert {:ok, %Snapshot{description: description}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", body)}} end
             )

    assert description =~ "[REDACTED:credential]"
    refute description =~ "not-a-known-prefix-secret"
    refute description =~ "unrecognized-api-key"
    refute description =~ "dXNlcjpwYXNzd29yZA=="
  end

  test "maps not-found and rate-limit errors without response content" do
    identity = identity(42, "I42")

    assert {:error, %Failure{kind: :not_found}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 404, body: %{"message" => "private /tmp/response"}}} end
             )

    assert {:error, %Failure{kind: :rate_limited, retry_after: 30}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 429, headers: [{"retry-after", "30"}], body: %{"message" => "limit"}}} end
             )
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
               TicketDetail.fetch(identity,
                 configured_repo: @configured,
                 request_fun: fn _request -> response end
               )

      assert Map.keys(failure) == [:__struct__, :kind, :retry_after]
    end
  end

  test "maps a successful but non-map provider response to schema failure" do
    identity = identity(42, "I42")

    assert {:error, %Failure{kind: :schema}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: ["not", "an", "issue"]}} end
             )
  end

  test "rejects oversized provider text rather than publishing it" do
    identity = identity(42, "I42")

    assert {:error, %Failure{kind: :validation}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               max_description_bytes: 8,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", "too long!")}} end
             )
  end

  test "does not let an adapter option raise the hard description bound" do
    identity = identity(42, "I42")

    assert {:error, %Failure{kind: :validation}} =
             TicketDetail.fetch(identity,
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
               TicketDetail.fetch(identity,
                 configured_repo: @configured,
                 request_fun: fn _request -> {:ok, %{status: 200, body: issue}} end
               )
    end
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
