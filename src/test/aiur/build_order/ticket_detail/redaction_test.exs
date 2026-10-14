defmodule Aiur.BuildOrder.TicketDetailRedactionTest do
  use ExUnit.Case, async: false

  alias Aiur.{BuildOrder.TicketDetail, TrackerIdentity}
  alias Aiur.BuildOrder.TicketDetail.{Failure, Snapshot}
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
