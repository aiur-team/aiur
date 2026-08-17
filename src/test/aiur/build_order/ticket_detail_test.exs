defmodule Aiur.BuildOrder.TicketDetailTest do
  use ExUnit.Case, async: false

  alias Aiur.{BuildOrder.TicketDetail, TrackerIdentity}
  alias Aiur.BuildOrder.TicketDetail.{Destinations, Failure, PullRequestDestination, Snapshot}
  alias Aiur.GitHub.ResourceStore

  # `Aiur.GitHub.ResourceStore` is global by design — the whole point is that a
  # resource fetched by one reader satisfies every other — so without this a body
  # stored for issue 42 by one case is served to the next case instead of its own
  # stub, and the stub it injected is never called.
  setup do
    ResourceStore.reset()
    :ok
  end

  @configured {"owner", "repo"}
  @token_cache_key {Aiur.GitHub.Config, :resolved_token}
  @transport_test_options_key :github_transport_test_options

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
             fetch(identity,
               configured_repo: @configured
             )
  end

  test "rejects another repository before the request function is invoked" do
    foreign = identity(42, "Foreign42", {"other", "repo"})

    assert {:error, %Failure{kind: :nonfetchable_repository}} =
             fetch(foreign,
               configured_repo: @configured,
               request_fun: fn _request -> flunk("transport must not be called") end
             )
  end

  test "rejects malformed repository components before the request function is invoked" do
    for {field, value} <- [owner: "owner name", owner: "owner?query", repository: "repo#fragment", repository: ".."] do
      malformed = Map.put(identity(42, "I42"), field, value)

      assert {:error, %Failure{kind: :nonfetchable_repository}} =
               fetch(malformed,
                 configured_repo: @configured,
                 request_fun: fn _request -> flunk("transport must not be called") end
               )
    end

    assert {:error, %Failure{kind: :configuration}} =
             fetch(identity(42, "I42"),
               configured_repo: {"owner?query", "repo"},
               request_fun: fn _request -> flunk("transport must not be called") end
             )
  end

  test "rejects repository delimiters before configuration or provider work" do
    for {field, value} <- [
          owner: "owner/path",
          owner: "owner?query",
          owner: "owner#fragment",
          owner: " owner",
          owner: "owner ",
          owner: ".",
          repository: "repo/path",
          repository: "repo?query",
          repository: "repo#fragment",
          repository: "..",
          repository: String.duplicate("r", 101)
        ] do
      malformed = Map.put(identity(42, "I42"), field, value)

      assert {:error, %Failure{kind: :nonfetchable_repository}} =
               fetch(malformed,
                 configured_repo: fn -> flunk("configuration reader must not be invoked") end,
                 request_fun: fn _request -> flunk("transport must not be called") end
               )
    end
  end

  test "rejects an unjoinable identity before transport work" do
    identity = TrackerIdentity.unjoinable(:legacy, owner: "owner", repository: "repo", identifier: 42)

    assert {:error, %Failure{kind: :nonfetchable_repository}} =
             fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> flunk("transport must not be called") end
             )
  end

  test "bounds a ticket identifier before provider URL construction" do
    identity = identity(42, "I42")
    boundary = %{identity | identifier: String.duplicate("9", 19)}
    oversized = %{identity | identifier: String.duplicate("9", 20)}

    assert {:ok, ^boundary, @configured} =
             TicketDetail.fetchable_identity(boundary, configured_repo: @configured)

    assert {:error, %Failure{kind: :nonfetchable_repository}} =
             fetch(oversized,
               configured_repo: @configured,
               request_fun: fn _request -> flunk("transport must not be called") end
             )
  end

  test "does not accept same-number data for a different provider node" do
    identity = identity(42, "I42")

    assert {:error, %Failure{kind: :provider_identity_mismatch}} =
             fetch(identity,
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
               fetch(identity,
                 configured_repo: @configured,
                 request_fun: fn _request -> {:ok, %{status: 200, body: response}} end
               )
    end

    invalid_lifecycle = Map.put(issue(42, "I42"), "state", "invented")

    assert {:error, %Failure{kind: :validation}} =
             fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request ->
                 {:ok, %{status: 200, body: invalid_lifecycle}}
               end
             )

    for invalid_lifecycle <- [
          Map.delete(issue(42, "I42"), "state"),
          Map.delete(issue(42, "I42"), "state_reason"),
          issue(42, "I42") |> Map.put("state", "open") |> Map.put("state_reason", "completed"),
          issue(42, "I42") |> Map.put("state", "closed") |> Map.put("state_reason", nil)
        ] do
      complete_lifecycle? =
        Map.has_key?(invalid_lifecycle, "state") and
          Map.has_key?(invalid_lifecycle, "state_reason")

      expected_kind = if complete_lifecycle?, do: :validation, else: :schema

      assert {:error, %Failure{kind: ^expected_kind}} =
               fetch(identity,
                 configured_repo: @configured,
                 request_fun: fn _request ->
                   {:ok, %{status: 200, body: invalid_lifecycle}}
                 end
               )
    end
  end

  test "rejects pull-request payloads from the issue endpoint" do
    identity = identity(42, "I42")

    assert {:error, %Failure{kind: :schema}} =
             fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "pull_request", %{})}} end
             )
  end

  test "keeps an explicit absent body distinct from a partial or malformed description" do
    identity = identity(42, "I42")

    assert {:ok, %Snapshot{description: nil}} =
             fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", nil)}} end
             )

    assert {:error, %Failure{kind: :schema}} =
             fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.delete(issue(42, "I42"), "body")}} end
             )

    assert {:error, %Failure{kind: :validation}} =
             fetch(identity,
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
             fetch(identity,
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
             fetch(identity,
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
        "//alice:network-path-secret@example.test/private\n" <>
        ~S({\"Authorization\":\"escaped-json-secret\"}) <>
        "\n" <>
        ~s({&quot;Cookie&quot;:&quot;entity-json-secret&quot;}) <>
        "\n" <>
        "file:///etc/passwd file:///home/alice/.ssh/id_ed25519 /nix/store/private-package\n" <>
        "\\\\server\\share\\private.txt local-workspace=/workspace local-tmp=/tmp\n" <>
        "https://example.test/nix/store/render https://example.test/workspace https://example.test/tmp\n" <>
        "-----BEGIN OPENSSH PRIVATE KEY-----\nunterminated-key-material"

    assert {:ok, %Snapshot{description: description}} =
             fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", body)}} end
             )

    assert description =~ "[REDACTED:credential]"
    assert description =~ "[REDACTED:local_path]"
    assert description =~ "https://example.test/nix/store/render"
    assert description =~ "https://example.test/workspace"
    assert description =~ "https://example.test/tmp"
    refute description =~ "BEGIN OPENSSH PRIVATE KEY"
    refute description =~ "private-key-material"
    refute description =~ "unterminated-key-material"
    refute description =~ "alice:s3cr3t"
    refute description =~ "network-path-secret"
    refute description =~ "escaped-json-secret"
    refute description =~ "entity-json-secret"
    refute description =~ "file:///etc/passwd"
    refute description =~ "file:///home/alice/.ssh/id_ed25519"
    refute description =~ "/nix/store/private-package"
    refute description =~ "\\\\server\\share\\private.txt"
    refute description =~ "local-workspace=/workspace"
    refute description =~ "local-tmp=/tmp"
  end

  test "redacts escaped header pairs, credential elements, PGP blocks, and network shares" do
    identity = identity(42, "I42")

    body =
      ~S([[\"Authorization\", \"escaped-header-secret\"]]) <>
        "\n" <>
        ~S({\"Cookie\", \"escaped-curly-secret\"}) <>
        "\n" <>
        "<password>xml-password-secret</password>\n" <>
        ~s(<input name="api_key" value="html-api-key-secret">) <>
        "\n" <>
        ~s(<input value="html-value-first-secret" name="password">) <>
        "\n" <>
        ~s(<token value="xml-attribute-secret" />) <>
        "\n" <>
        "-----BEGIN PGP PRIVATE KEY BLOCK-----\npgp-private-key-secret\n" <>
        "-----END PGP PRIVATE KEY BLOCK-----\n" <>
        "//server/share/private.txt \\\\server/share\\private.txt " <>
        "https://example.test/server/share/private.txt"

    assert {:ok, %Snapshot{description: description}} =
             fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request ->
                 {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", body)}}
               end
             )

    assert description =~ "[REDACTED:credential]"
    assert description =~ "[REDACTED:local_path]"
    assert description =~ "https://example.test/server/share/private.txt"

    for secret <- [
          "escaped-header-secret",
          "escaped-curly-secret",
          "xml-password-secret",
          "html-api-key-secret",
          "html-value-first-secret",
          "xml-attribute-secret",
          "pgp-private-key-secret",
          "//server/share/private.txt",
          "\\\\server/share\\private.txt"
        ] do
      refute description =~ secret
    end
  end

  test "rejects oversized raw descriptions before sanitization" do
    identity = identity(42, "I42")
    body = "Authorization: Bearer " <> String.duplicate("x", 64)

    assert {:error, %Failure{kind: :validation}} =
             fetch(identity,
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
        "Cookie: public-cookie\n private-folded-cookie\nX-Trace: retained\n" <>
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
             fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", body)}} end
             )

    assert description =~ "[REDACTED:credential]"
    refute description =~ "not-a-known-prefix-secret"
    refute description =~ "unrecognized-api-key"
    refute description =~ "private-folded-cookie"
    assert description =~ "X-Trace: retained"
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

  test "redacts command credential flags, CDATA credentials, and singleton local paths" do
    identity = identity(42, "I42")

    body =
      "mysql --password supersecret\n" <>
        "deploy --api-key anothersecret\n" <>
        "<password><![CDATA[xml-secret]]></password>\n" <>
        "machine api.example login deploy password netrc-secret\n" <>
        ~S({"\u0070assword":"escaped-name-secret"}) <>
        "\n/etc /home /opt /root /usr /var /etc/passwd /home/alice /root/.ssh/id_ed25519\n" <>
        "https://example.test/etc docs/etc\n" <>
        "<password>unterminated-element-secret"

    assert {:ok, %Snapshot{description: description}} =
             fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request ->
                 {:ok, %{status: 200, body: Map.put(issue(42, "I42"), "body", body)}}
               end
             )

    assert description =~ "[REDACTED:credential]"
    assert description =~ "[REDACTED:local_path]"
    assert description =~ "https://example.test/etc"
    assert description =~ "docs/etc"

    for secret <- [
          "supersecret",
          "anothersecret",
          "xml-secret",
          "netrc-secret",
          "escaped-name-secret",
          "unterminated-element-secret"
        ] do
      refute description =~ secret
    end

    refute Regex.match?(~r{(?<![A-Za-z0-9._/-])/(?:etc|home|opt|root|usr|var)(?![A-Za-z0-9._/-])}u, description)
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
