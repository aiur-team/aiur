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

  test "rejects malformed repository components before the request function is invoked" do
    for {field, value} <- [owner: "owner name", owner: "owner?query", repository: "repo#fragment", repository: ".."] do
      malformed = Map.put(identity(42, "I42"), field, value)

      assert {:error, %Failure{kind: :nonfetchable_repository}} =
               TicketDetail.fetch(malformed,
                 configured_repo: @configured,
                 request_fun: fn _request -> flunk("transport must not be called") end
               )
    end

    assert {:error, %Failure{kind: :configuration}} =
             TicketDetail.fetch(identity(42, "I42"),
               configured_repo: {"owner?query", "repo"},
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

  test "does not accept noncanonical response repository or lifecycle data in a complete snapshot" do
    identity = identity(42, "I42")

    for repository_url <- [
          "https://api.github.com/repos/other/repo",
          "https://user@api.github.com/repos/owner/repo",
          "https://api.github.com:443/repos/owner/repo",
          "https://api.github.com:444/repos/owner/repo",
          "https://api.github.com/not-repos/owner/repo",
          "https://api.github.com/repos/owner/repo/extra",
          "https://api.github.com/repos/owner/repo?private=1",
          "https://api.github.com/repos/owner/repo#fragment"
        ] do
      response = Map.put(issue(42, "I42"), "repository_url", repository_url)

      assert {:error, %Failure{kind: :provider_identity_mismatch}} =
               TicketDetail.fetch(identity,
                 configured_repo: @configured,
                 request_fun: fn _request -> {:ok, %{status: 200, body: response}} end
               )
    end

    invalid_lifecycle = Map.put(issue(42, "I42"), "state", "invented")

    assert {:error, %Failure{kind: :validation}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request ->
                 {:ok, %{status: 200, body: invalid_lifecycle}}
               end
             )
  end

  test "rejects pull-request payloads from the issue endpoint" do
    identity = identity(42, "I42")

    assert {:error, %Failure{kind: :schema}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "pull_request", %{})}} end
             )
  end

  test "keeps an explicit absent body distinct from a partial or malformed description" do
    identity = identity(42, "I42")

    assert {:ok, %Snapshot{description: nil}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", nil)}} end
             )

    assert {:error, %Failure{kind: :schema}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.delete(issue(42, "I42"), "body")}} end
             )

    assert {:error, %Failure{kind: :validation}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", 42)}} end
             )
  end

  test "redacts credentials and common local paths before detail reaches a snapshot" do
    identity = identity(42, "I42")

    body =
      "token ghp_abcdefghijklmnopqrstuvwxyz0123456789 and /home/alice/private.txt " <>
        "/root/.ssh/id_ed25519 /var/lib/aiur/private.db /workspace/project/secret.txt " <>
        "/etc/passwd /opt/aiur/private.env"

    assert {:ok, %Snapshot{description: description}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", body)}} end
             )

    assert description =~ "[REDACTED:ghp]"
    assert description =~ "[REDACTED:local_path]"
    refute description =~ "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    refute description =~ "/home/alice/private.txt"
    refute description =~ "/root/.ssh/id_ed25519"
    refute description =~ "/var/lib/aiur/private.db"
    refute description =~ "/workspace/project/secret.txt"
    refute description =~ "/etc/passwd"
    refute description =~ "/opt/aiur/private.env"
  end

  test "preserves ordinary URL and path text while redacting local paths" do
    identity = identity(42, "I42")
    body = "https://example.test/etc/passwd and docs/etc/passwd and error:/root/.ssh/id_ed25519"

    assert {:ok, %Snapshot{description: description}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request ->
                 {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", body)}}
               end
             )

    assert description =~ "https://example.test/etc/passwd"
    assert description =~ "docs/etc/passwd"
    refute description =~ "/root/.ssh/id_ed25519"
  end

  test "redacts structural credentials and local paths before detail reaches a snapshot" do
    identity = identity(42, "I42")

    body =
      "-----BEGIN OPENSSH PRIVATE KEY-----\nprivate-key-material\n-----END OPENSSH PRIVATE KEY-----\n" <>
        "https://alice:s3cr3t@example.test/private\n" <>
        "file:///etc/passwd file:///home/alice/.ssh/id_ed25519 /nix/store/private-package\n" <>
        "https://example.test/nix/store/render"

    assert {:ok, %Snapshot{description: description}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", body)}} end
             )

    assert description =~ "[REDACTED:credential]"
    assert description =~ "[REDACTED:local_path]"
    assert description =~ "https://example.test/nix/store/render"
    refute description =~ "BEGIN OPENSSH PRIVATE KEY"
    refute description =~ "private-key-material"
    refute description =~ "alice:s3cr3t"
    refute description =~ "file:///etc/passwd"
    refute description =~ "file:///home/alice/.ssh/id_ed25519"
    refute description =~ "/nix/store/private-package"
  end

  test "rejects oversized raw descriptions before sanitization" do
    identity = identity(42, "I42")
    body = "Authorization: Bearer " <> String.duplicate("x", 64)

    assert {:error, %Failure{kind: :validation}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               max_description_bytes: 32,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", body)}} end
             )
  end

  test "redacts structured sensitive headers, assignments, and generic credentials before snapshot storage" do
    identity = identity(42, "I42")

    body =
      "Authorization: Bearer not-a-known-prefix-secret\n" <>
        "X-Api-Key: unrecognized-api-key\n" <>
        "inline Basic dXNlcjpwYXNzd29yZA==\n" <>
        ~s({"Authorization":"Bearer json-secret","headers":{"X-Api-Key":"json-key"}}) <>
        "\n" <>
        "curl --header 'Cookie: curl-cookie' https://example.test\n" <>
        ~s([{"Proxy-Authorization", "Basic header-list-secret"}]) <>
        "\nGITHUB_TOKEN=assignment-token\napi_key = assignment-api-key\n" <>
        "password=plain-password\nDB_PASSWORD=assignment-password\npasswd: header-password\n" <>
        ~s({"passphrase":"structured-passphrase","private_key":"structured-private-key"}) <>
        "\n" <>
        ~s([["Authorization", "bracket-pair-secret"]]) <>
        "\n" <>
        ~s([[&quot;Cookie&quot;, &quot;entity-pair-secret&quot;]]) <>
        "\n" <>
        ~s([["private-key", "pair-private-key"]])

    assert {:ok, %Snapshot{description: description}} =
             TicketDetail.fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", body)}} end
             )

    assert description =~ "[REDACTED:credential]"
    refute description =~ "not-a-known-prefix-secret"
    refute description =~ "unrecognized-api-key"
    refute description =~ "dXNlcjpwYXNzd29yZA=="
    refute description =~ "json-secret"
    refute description =~ "json-key"
    refute description =~ "curl-cookie"
    refute description =~ "header-list-secret"
    refute description =~ "assignment-token"
    refute description =~ "assignment-api-key"
    refute description =~ "plain-password"
    refute description =~ "assignment-password"
    refute description =~ "header-password"
    refute description =~ "structured-passphrase"
    refute description =~ "structured-private-key"
    refute description =~ "bracket-pair-secret"
    refute description =~ "entity-pair-secret"
    refute description =~ "pair-private-key"
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

  test "clamps provider retry hints to the documented public bound" do
    identity = identity(42, "I42")
    maximum = TicketDetail.max_retry_after_seconds()

    for {retry_after, expected} <- [{maximum, maximum}, {maximum + 1, maximum}, {9_999_999, maximum}] do
      assert {:error, %Failure{kind: :rate_limited, retry_after: ^expected}} =
               TicketDetail.fetch(identity,
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
