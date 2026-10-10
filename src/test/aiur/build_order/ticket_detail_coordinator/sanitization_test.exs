defmodule Aiur.BuildOrder.TicketDetailCoordinatorSanitizationTest do
  use ExUnit.Case, async: false

  alias Aiur.{BuildOrder.TicketDetail, TrackerIdentity}
  alias Aiur.BuildOrder.TicketDetail.{Snapshot, State}
  alias Aiur.BuildOrder.TicketDetailCoordinator
  alias Aiur.GitHub.ResourceStore

  @configured {"owner", "repo"}

  # The coordinator no longer holds GitHub bodies — `Aiur.GitHub.ResourceStore`
  # does, keyed by the issue rather than by the reader. That is the point of the
  # change, and it means these cases, which all read issue 42 with a different
  # stubbed body, would otherwise serve each other's bodies.
  setup do
    ResourceStore.reset()
    :ok
  end

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end

  test "publishes structured credential-sanitized detail without the raw provider body" do
    identity = identity(42, "I42")

    body =
      "Authorization: Bearer not-a-known-prefix-secret\n" <>
        "Cookie: private-session-cookie\n" <>
        "Cookie: public-cookie\n private-folded-cookie\n" <>
        "inline Basic dXNlcjpwYXNzd29yZA==\n" <>
        ~s({"Authorization":"Bearer json-secret"}) <>
        "\n" <>
        "curl -H 'X-Api-Key: curl-key' https://example.test\n" <>
        ~s([{"Cookie", "header-list-cookie"}]) <>
        "\nGITHUB_TOKEN=assignment-token\n" <>
        "password=plain-password\nDB_PASSWORD=assignment-password\npasswd: header-password\n" <>
        ~s({"passphrase":"structured-passphrase","private_key":"structured-private-key"}) <>
        "\n" <>
        ~s([["Authorization", "bracket-pair-secret"]]) <>
        "\n" <>
        ~s([[&quot;Cookie&quot;, &quot;entity-pair-secret&quot;]]) <>
        "\n" <>
        ~s([["private-key", "pair-private-key"]]) <>
        " /root/.ssh/id_ed25519 /var/lib/aiur/private.db /workspace/project/secret.txt " <>
        "/etc/passwd /opt/aiur/private.env\n" <>
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

    {:ok, cache} =
      start_cache(
        reader: fn requested_identity ->
          TicketDetail.fetch(requested_identity,
            configured_repo: @configured,
            relationship_reader: &no_linked_pull_requests/2,
            request_fun: fn _request ->
              {:ok, %{status: 200, body: detail_issue(requested_identity, body)}}
            end
          )
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive {:ticket_detail_updated, %State{detail: %Snapshot{description: description}}}, 2_000
    assert description =~ "[REDACTED:credential]"
    assert description =~ "[REDACTED:local_path]"
    assert description =~ "https://example.test/nix/store/render"
    assert description =~ "https://example.test/workspace"
    assert description =~ "https://example.test/tmp"
    refute description =~ "not-a-known-prefix-secret"
    refute description =~ "private-session-cookie"
    refute description =~ "private-folded-cookie"
    refute description =~ "dXNlcjpwYXNzd29yZA=="
    refute description =~ "json-secret"
    refute description =~ "curl-key"
    refute description =~ "header-list-cookie"
    refute description =~ "assignment-token"
    refute description =~ "plain-password"
    refute description =~ "assignment-password"
    refute description =~ "header-password"
    refute description =~ "structured-passphrase"
    refute description =~ "structured-private-key"
    refute description =~ "bracket-pair-secret"
    refute description =~ "entity-pair-secret"
    refute description =~ "pair-private-key"
    refute description =~ "/root/.ssh/id_ed25519"
    refute description =~ "/var/lib/aiur/private.db"
    refute description =~ "/workspace/project/secret.txt"
    refute description =~ "/etc/passwd"
    refute description =~ "/opt/aiur/private.env"
    refute description =~ "BEGIN OPENSSH PRIVATE KEY"
    refute description =~ "private-key-material"
    refute description =~ "unterminated-key-material"
    refute description =~ "alice:s3cr3t"
    refute description =~ "network-path-secret"
    refute description =~ "escaped-json-secret"
    refute description =~ "entity-json-secret"
    refute description =~ "file:///home/alice/.ssh/id_ed25519"
    refute description =~ "/nix/store/private-package"
    refute description =~ "\\\\server\\share\\private.txt"
    refute description =~ "local-workspace=/workspace"
    refute description =~ "local-tmp=/tmp"
  end

  test "does not publish newly structured credentials or network paths" do
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
        "//server/share/private.txt \\\\server/share\\private.txt"

    {:ok, cache} =
      start_cache(
        reader: fn requested_identity ->
          TicketDetail.fetch(requested_identity,
            configured_repo: @configured,
            relationship_reader: &no_linked_pull_requests/2,
            request_fun: fn _request ->
              {:ok, %{status: 200, body: detail_issue(requested_identity, body)}}
            end
          )
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{detail: %Snapshot{description: description}}}, 2_000

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

  test "does not publish command credentials, CDATA secrets, or singleton local paths" do
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

    {:ok, cache} =
      start_cache(
        reader: fn requested_identity ->
          TicketDetail.fetch(requested_identity,
            configured_repo: @configured,
            relationship_reader: &no_linked_pull_requests/2,
            request_fun: fn _request ->
              {:ok, %{status: 200, body: detail_issue(requested_identity, body)}}
            end
          )
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{detail: %Snapshot{description: description}}}, 2_000

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

  defp start_cache(opts) do
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    TicketDetailCoordinator.start_link(
      Keyword.merge(
        [
          name: nil,
          task_supervisor: task_supervisor,
          configured_repo: @configured,
          configuration_subscriber: fn _pid -> :ok end,
          now: fn -> ~U[2026-07-14 09:00:00Z] end,
          clock_ms: fn -> 0 end
        ],
        opts
      )
    )
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

  defp detail_issue(identity, body) do
    %{
      "node_id" => identity.provider_id,
      "number" => String.to_integer(identity.identifier),
      "title" => "Configured ticket",
      "body" => body,
      "html_url" => "https://github.com/owner/repo/issues/#{identity.identifier}",
      "repository_url" => "https://api.github.com/repos/owner/repo",
      "state" => "open",
      "state_reason" => nil,
      "created_at" => "2026-07-01T10:00:00Z",
      "updated_at" => "2026-07-02T11:00:00Z"
    }
  end

  defp no_linked_pull_requests(_identity, _repository),
    do: {:ok, %{nodes: [], truncated?: false}}
end
