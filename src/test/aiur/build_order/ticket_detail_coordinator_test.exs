defmodule Aiur.BuildOrder.TicketDetailCoordinatorTest do
  use ExUnit.Case, async: false

  alias Aiur.{BuildOrder.Lifecycle, BuildOrder.TicketDetail, TrackerIdentity}
  alias Aiur.BuildOrder.TicketDetail.{Failure, Snapshot, State}
  alias Aiur.BuildOrder.TicketDetailCoordinator
  alias Aiur.GitHub.ResourceStore

  @configured {"owner", "repo"}
  @workflow_configuration_topic "workflow_store:configuration"

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

  test "coalesces concurrent cold demand and publishes one complete generation" do
    parent = self()
    identity = identity(42, "I42")

    {:ok, cache} =
      start_cache(
        reader: fn _identity ->
          send(parent, {:reader_started, self()})

          receive do
            :finish -> {:ok, snapshot(identity, "first")}
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable, generation: 1}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:reader_started, reader_pid}, 2_000

    for _ <- 1..3 do
      assert {:ok, %State{health: :unavailable, generation: 1}} = TicketDetailCoordinator.request(cache, identity)
    end

    refute_receive {:reader_started, _reader_pid}
    send(reader_pid, :finish)

    assert_receive(
      {:ticket_detail_updated, %State{health: :healthy, generation: 1, detail: %Snapshot{title: "first"}}},
      2_000
    )

    assert {:ok, %State{health: :healthy, generation: 1, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.current(cache, identity)
  end

  test "propagates a LiveView request origin into the refresh task" do
    parent = self()
    identity = identity(42, "I42")

    {:ok, cache} =
      start_cache(
        reader: fn _identity ->
          send(parent, {:view_originated, Aiur.GitHub.RequestOrigin.view_originated?()})
          {:ok, snapshot(identity, "detail")}
        end
      )

    Aiur.GitHub.RequestOrigin.carry(true, fn ->
      assert {:ok, %State{generation: 1}} = TicketDetailCoordinator.request(cache, identity)
    end)

    assert_receive {:view_originated, true}, 2_000
  end

  test "constant repository fixture does not subscribe to workflow configuration" do
    parent = self()
    identity = identity(42, "I42")

    {:ok, cache} =
      start_cache(
        reader: fn _identity ->
          send(parent, {:reader_started, self()})

          receive do
            :finish -> {:ok, snapshot(identity, "first")}
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:reader_started, reader_pid}, 2_000

    refute Enum.any?(
             Registry.lookup(Aiur.PubSub, @workflow_configuration_topic),
             fn {subscriber, _metadata} -> subscriber == cache end
           )

    send(reader_pid, :finish)

    assert_receive {
                     :ticket_detail_updated,
                     %State{generation: 1, health: :healthy, detail: %Snapshot{title: "first"}}
                   },
                   2_000
  end

  test "rejects another repository before cache admission or reader invocation" do
    foreign = identity(42, "Foreign42", {"other", "repo"})

    {:ok, cache} =
      start_cache(reader: fn _identity -> flunk("reader must not be invoked") end)

    assert {:error, %Failure{kind: :nonfetchable_repository}} = TicketDetailCoordinator.request(cache, foreign)
    assert %{entries: %{}} = :sys.get_state(cache)
  end

  test "keeps last-known-good detail stale when a refresh fails" do
    identity = identity(42, "I42")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, results} = Agent.start_link(fn -> [{:ok, snapshot(identity, "first")}, {:error, %Failure{kind: :timeout}}] end)

    {:ok, cache} =
      start_cache(
        freshness_ms: 10,
        clock_ms: fn -> Agent.get(clock, & &1) end,
        reader: fn _identity -> Agent.get_and_update(results, fn [result | rest] -> {result, rest} end) end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, detail: %Snapshot{title: "first"}}}, 2_000

    Agent.update(clock, fn _ -> 11 end)

    assert {:ok, %State{health: :stale, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.request(cache, identity)

    assert_receive {
                     :ticket_detail_updated,
                     %State{
                       health: :stale,
                       detail: %Snapshot{title: "first"},
                       failure: %Failure{kind: :timeout}
                     }
                   },
                   2_000
  end

  test "reports a cold failure as unavailable rather than fabricating detail" do
    identity = identity(42, "I42")
    {:ok, cache} = start_cache(reader: fn _identity -> {:error, %Failure{kind: :not_found}} end)

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable, detail: nil}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive {
                     :ticket_detail_updated,
                     %State{health: :unavailable, detail: nil, failure: %Failure{kind: :not_found}}
                   },
                   2_000
  end

  test "recovers from a cold failure only after a later successful demand" do
    identity = identity(42, "I42")
    {:ok, results} = Agent.start_link(fn -> [{:error, %Failure{kind: :timeout}}, {:ok, snapshot(identity, "recovered")}] end)

    {:ok, cache} =
      start_cache(reader: fn _identity -> Agent.get_and_update(results, fn [result | rest] -> {result, rest} end) end)

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive(
      {:ticket_detail_updated, %State{generation: 1, health: :unavailable, detail: nil}},
      2_000
    )

    assert {:ok, %State{generation: 2, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive(
      {:ticket_detail_updated, %State{generation: 2, health: :healthy, detail: %Snapshot{title: "recovered"}}},
      2_000
    )
  end

  test "bounds retention by evicting completed least-recently-used entries" do
    first = identity(1, "I1")
    second = identity(2, "I2")

    {:ok, cache} =
      start_cache(max_entries: 1, reader: fn identity -> {:ok, snapshot(identity, identity.identifier)} end)

    assert :ok = TicketDetailCoordinator.subscribe(cache, first)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, first)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, identity: ^first}}, 2_000

    assert :ok = TicketDetailCoordinator.subscribe(cache, second)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, second)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, identity: ^second}}, 2_000
    assert {:ok, %State{health: :unavailable, detail: nil}} = TicketDetailCoordinator.current(cache, first)
  end

  test "notifies every subscriber before evicting a completed entry" do
    parent = self()
    first = identity(1, "I1")
    second = identity(2, "I2")

    {:ok, cache} =
      start_cache(max_entries: 1, reader: fn identity -> {:ok, snapshot(identity, identity.identifier)} end)

    first_subscriber = subscribe_and_forward(cache, first, parent)
    second_subscriber = subscribe_and_forward(cache, first, parent)

    assert_receive {:detail_subscribed, ^first_subscriber}, 2_000
    assert_receive {:detail_subscribed, ^second_subscriber}, 2_000
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, first)

    assert_receive {:detail_update, ^first_subscriber, {:ticket_detail_updated, first_update}}, 2_000
    assert %State{generation: 1, health: :healthy, identity: ^first} = first_update

    assert_receive {:detail_update, ^second_subscriber, {:ticket_detail_updated, second_update}}, 2_000
    assert %State{generation: 1, health: :healthy, identity: ^first} = second_update

    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, second)

    assert_receive {
                     :detail_update,
                     ^first_subscriber,
                     {:ticket_detail_updated,
                      %State{
                        generation: 1,
                        health: :unavailable,
                        detail: nil,
                        identity: ^first,
                        failure: %Failure{kind: :evicted}
                      }}
                   },
                   2_000

    assert_receive {
                     :detail_update,
                     ^second_subscriber,
                     {:ticket_detail_updated,
                      %State{
                        generation: 1,
                        health: :unavailable,
                        detail: nil,
                        identity: ^first,
                        failure: %Failure{kind: :evicted}
                      }}
                   },
                   2_000

    assert {:ok, %State{health: :unavailable, detail: nil}} = TicketDetailCoordinator.current(cache, first)
  end

  test "does not evict an in-flight identity to exceed the configured capacity" do
    parent = self()
    first = identity(1, "I1")
    second = identity(2, "I2")

    {:ok, cache} =
      start_cache(
        max_entries: 1,
        reader: fn _identity ->
          send(parent, {:reader_started, self()})

          receive do
            :finish -> {:ok, snapshot(first, "first")}
          end
        end
      )

    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, first)
    assert_receive {:reader_started, reader_pid}, 2_000
    assert {:error, %Failure{kind: :capacity}} = TicketDetailCoordinator.request(cache, second)
    send(reader_pid, :finish)
  end

  test "cannot publish a snapshot from another ticket identity" do
    identity = identity(42, "I42")
    other_identity = identity(43, "I43")

    {:ok, cache} =
      start_cache(reader: fn _identity -> {:ok, snapshot(other_identity, "wrong ticket")} end)

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive {
                     :ticket_detail_updated,
                     %State{
                       health: :unavailable,
                       detail: nil,
                       failure: %Failure{kind: :provider_identity_mismatch}
                     }
                   },
                   2_000
  end

  test "evicts an in-flight detail when the configured repository changes" do
    parent = self()
    identity = identity(42, "I42")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    {:ok, cache} =
      start_cache(
        freshness_ms: 1,
        clock_ms: fn -> Agent.get(clock, & &1) end,
        reader: fn _identity ->
          case Agent.get_and_update(attempts, fn attempt -> {attempt + 1, attempt + 1} end) do
            1 ->
              {:ok, snapshot(identity, "first")}

            2 ->
              send(parent, {:reader_started, self()})

              receive do
                :finish -> {:ok, snapshot(identity, "stale repository")}
              end
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive(
      {:ticket_detail_updated, %State{generation: 1, health: :healthy, detail: %Snapshot{title: "first"}}},
      2_000
    )

    Agent.update(clock, fn _ -> 2 end)

    assert {:ok, %State{generation: 2, health: :stale, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.request(cache, identity)

    assert_receive {:reader_started, reader_pid}, 2_000
    assert @configured == inflight_repository(cache, identity)

    :sys.replace_state(cache, &Map.put(&1, :configured_repo, {"other", "repo"}))
    send(reader_pid, :finish)

    assert_receive {
                     :ticket_detail_updated,
                     %State{
                       generation: 2,
                       health: :unavailable,
                       detail: nil,
                       identity: ^identity,
                       failure: %Failure{kind: :evicted}
                     }
                   },
                   2_000

    assert %{entries: %{}} = :sys.get_state(cache)
  end

  test "reconciles idle subscribed detail before subscription and cannot resurrect it after a switch-back" do
    identity = identity(42, "I42")
    switched_identity = identity(42, "I42", {"other", "repo"})
    {:ok, repository} = Agent.start_link(fn -> @configured end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    {:ok, cache} =
      start_cache(
        configured_repo: fn -> Agent.get(repository, & &1) end,
        reader: fn requested_identity ->
          attempt = Agent.get_and_update(attempts, fn attempt -> {attempt + 1, attempt + 1} end)
          {:ok, snapshot(requested_identity, if(attempt == 1, do: "first", else: "second"))}
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, detail: %Snapshot{title: "first"}}}, 2_000

    Agent.update(repository, fn _repository -> {"other", "repo"} end)

    assert :ok = TicketDetailCoordinator.subscribe(cache, switched_identity)

    assert_receive {
                     :ticket_detail_updated,
                     %State{identity: ^identity, health: :unavailable, detail: nil, failure: %Failure{kind: :evicted}}
                   },
                   2_000

    assert {:error, %Failure{kind: :nonfetchable_repository}} = TicketDetailCoordinator.current(cache, identity)

    assert {:ok, %State{identity: ^switched_identity, health: :unavailable}} =
             TicketDetailCoordinator.current(cache, switched_identity)

    assert %{entries: %{}} = :sys.get_state(cache)

    Agent.update(repository, fn _repository -> @configured end)

    assert {:ok, %State{identity: ^identity, health: :unavailable, detail: nil}} =
             TicketDetailCoordinator.current(cache, identity)

    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, detail: %Snapshot{title: "second"}}}, 2_000
    assert Agent.get(attempts, & &1) == 2
  end

  test "reconciles an in-flight repository switch before capacity admission" do
    parent = self()
    first = identity(42, "I42")
    second = identity(43, "I43", {"other", "repo"})
    {:ok, repository} = Agent.start_link(fn -> @configured end)

    {:ok, cache} =
      start_cache(
        max_entries: 1,
        configured_repo: fn -> Agent.get(repository, & &1) end,
        reader: fn requested_identity ->
          send(parent, {:reader_started, requested_identity, self()})

          receive do
            :finish -> {:ok, snapshot(requested_identity, requested_identity.identifier)}
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, first)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, first)
    assert_receive {:reader_started, ^first, _first_reader}, 2_000

    Agent.update(repository, fn _repository -> {"other", "repo"} end)

    assert :ok = TicketDetailCoordinator.subscribe(cache, second)
    assert {:ok, %State{identity: ^second, health: :unavailable}} = TicketDetailCoordinator.request(cache, second)

    assert_receive {
                     :ticket_detail_updated,
                     %State{identity: ^first, health: :unavailable, detail: nil, failure: %Failure{kind: :evicted}}
                   },
                   2_000

    assert_receive {:reader_started, ^second, second_reader}, 2_000
    send(second_reader, :finish)
    assert_receive {:ticket_detail_updated, %State{identity: ^second, health: :healthy}}, 2_000
    assert %{entries: entries} = :sys.get_state(cache)
    assert map_size(entries) == 1
  end

  test "evicts idle subscribed detail when a validated configuration generation changes" do
    parent = self()
    identity = identity(42, "I42")
    {:ok, repository} = Agent.start_link(fn -> @configured end)

    {:ok, cache} =
      start_cache(
        configured_repo: fn -> Agent.get(repository, & &1) end,
        configuration_subscriber: fn pid -> send(parent, {:configuration_subscribed, pid}) end,
        reader: fn requested_identity -> {:ok, snapshot(requested_identity, "first")} end
      )

    assert_receive {:configuration_subscribed, ^cache}, 2_000
    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, identity: ^identity}}, 2_000

    Agent.update(repository, fn _repository -> {"other", "repo"} end)
    send(cache, {:workflow_config_updated, 2})

    assert_receive {
                     :ticket_detail_updated,
                     %State{identity: ^identity, health: :unavailable, detail: nil, failure: %Failure{kind: :evicted}}
                   },
                   2_000

    assert %{entries: %{}} = :sys.get_state(cache)
  end

  test "configuration reader failure is typed and preserves last-known-good detail" do
    identity = identity(42, "I42")
    {:ok, mode} = Agent.start_link(fn -> :healthy end)

    {:ok, cache} =
      start_cache(
        configured_repo: fn ->
          case Agent.get(mode, & &1) do
            :healthy -> @configured
            :failed -> raise "configured repository unavailable"
          end
        end,
        reader: fn requested_identity -> {:ok, snapshot(requested_identity, "first")} end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, detail: %Snapshot{title: "first"}}}, 2_000

    Agent.update(mode, fn _mode -> :failed end)

    assert {:error, %Failure{kind: :configuration}} = TicketDetailCoordinator.current(cache, identity)

    assert_receive {
                     :ticket_detail_updated,
                     %State{health: :stale, detail: %Snapshot{title: "first"}, failure: %Failure{kind: :configuration}}
                   },
                   2_000

    assert Process.alive?(cache)

    Agent.update(mode, fn _mode -> :healthy end)

    assert {:ok, %State{health: :healthy, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.current(cache, identity)
  end

  test "configuration failure cancels an in-flight refresh without losing last-known-good detail" do
    parent = self()
    identity = identity(42, "I42")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    {:ok, mode} = Agent.start_link(fn -> :healthy end)

    {:ok, cache} =
      start_cache(
        freshness_ms: 1,
        clock_ms: fn -> Agent.get(clock, & &1) end,
        configured_repo: fn ->
          case Agent.get(mode, & &1) do
            :healthy -> @configured
            :failed -> raise "configured repository unavailable"
          end
        end,
        reader: fn requested_identity ->
          case Agent.get_and_update(attempts, fn attempt -> {attempt + 1, attempt + 1} end) do
            1 ->
              {:ok, snapshot(requested_identity, "first")}

            2 ->
              send(parent, {:reader_started, self()})

              receive do
                :finish -> {:ok, snapshot(requested_identity, "late")}
              end
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, detail: %Snapshot{title: "first"}}}, 2_000

    Agent.update(clock, fn _clock -> 2 end)

    assert {:ok, %State{health: :stale, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.request(cache, identity)

    assert_receive {:reader_started, reader_pid}, 2_000
    ref = inflight_ref(cache, identity)
    Agent.update(mode, fn _mode -> :failed end)

    assert {:error, %Failure{kind: :configuration}} = TicketDetailCoordinator.current(cache, identity)

    assert_receive {
                     :ticket_detail_updated,
                     %State{health: :stale, detail: %Snapshot{title: "first"}, failure: %Failure{kind: :configuration}}
                   },
                   2_000

    refute Process.alive?(reader_pid)
    send(cache, {ref, {:ok, snapshot(identity, "late")}})
    cache_barrier(cache)
    refute_receive {:ticket_detail_updated, %State{detail: %Snapshot{title: "late"}}}
  end

  test "fences an in-flight completion with one atomic configuration snapshot" do
    parent = self()
    identity = identity(42, "I42")
    {:ok, configuration} = Agent.start_link(fn -> {@configured, 1} end)

    {:ok, cache} =
      start_cache(
        configuration_snapshot: fn -> Agent.get(configuration, & &1) end,
        reader: fn _identity ->
          send(parent, {:reader_started, self()})

          receive do
            :finish -> {:ok, snapshot(identity, "stale-generation")}
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:reader_started, reader_pid}, 2_000
    ref = inflight_ref(cache, identity)

    Agent.update(configuration, fn _snapshot -> {@configured, 2} end)
    send(cache, {ref, {:ok, snapshot(identity, "stale-generation")}})
    cache_barrier(cache)

    refute_receive {:ticket_detail_updated, %State{detail: %Snapshot{title: "stale-generation"}}}
    refute Process.alive?(reader_pid)

    assert {:ok, %State{health: :unavailable, detail: nil, generation: :unknown}} =
             TicketDetailCoordinator.current(cache, identity)
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

  test "survives task-supervisor outage, preserves LKG, and recovers on a later demand" do
    identity = identity(42, "I42")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    {:ok, failed_supervisor} = Task.Supervisor.start_link()

    {:ok, cache} =
      start_cache(
        freshness_ms: 1,
        task_supervisor: failed_supervisor,
        clock_ms: fn -> Agent.get(clock, & &1) end,
        reader: fn _identity ->
          attempt = Agent.get_and_update(attempts, fn value -> {value + 1, value + 1} end)
          {:ok, snapshot(identity, if(attempt == 1, do: "first", else: "recovered"))}
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive(
      {:ticket_detail_updated, %State{generation: 1, health: :healthy, detail: %Snapshot{title: "first"}}},
      2_000
    )

    :ok = GenServer.stop(failed_supervisor)
    Agent.update(clock, fn _ -> 2 end)

    assert {:ok, %State{generation: 2, health: :stale, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.request(cache, identity)

    assert_receive {:ticket_detail_updated, outage_state}, 2_000

    assert %State{
             generation: 2,
             health: :stale,
             detail: %Snapshot{title: "first"},
             failure: %Failure{kind: :transport}
           } = outage_state

    assert Process.alive?(cache)
    {:ok, recovered_supervisor} = Task.Supervisor.start_link()
    :sys.replace_state(cache, &Map.put(&1, :task_supervisor, recovered_supervisor))

    assert {:ok, %State{generation: 3, health: :stale, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.request(cache, identity)

    assert_receive {:ticket_detail_updated,
                    %State{
                      generation: 3,
                      health: :healthy,
                      detail: %Snapshot{title: "recovered"}
                    }},
                   2_000
  end

  test "survives rejected task startup and recovers after a healthy supervisor is configured" do
    identity = identity(42, "I42")
    {:ok, rejecting_supervisor} = Task.Supervisor.start_link(max_children: 0)

    {:ok, cache} =
      start_cache(
        task_supervisor: rejecting_supervisor,
        reader: fn _identity -> {:ok, snapshot(identity, "recovered")} end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)

    assert {:ok, %State{generation: 1, health: :unavailable, failure: %Failure{kind: :transport}}} =
             TicketDetailCoordinator.request(cache, identity)

    assert_receive {:ticket_detail_updated,
                    %State{
                      generation: 1,
                      health: :unavailable,
                      failure: %Failure{kind: :transport}
                    }},
                   2_000

    assert Process.alive?(cache)
    {:ok, healthy_supervisor} = Task.Supervisor.start_link()
    :sys.replace_state(cache, &Map.put(&1, :task_supervisor, healthy_supervisor))

    assert {:ok, %State{generation: 2, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive {:ticket_detail_updated,
                    %State{
                      generation: 2,
                      health: :healthy,
                      detail: %Snapshot{title: "recovered"}
                    }},
                   2_000
  end

  test "times out cold demand, terminates its task, and ignores late completion" do
    parent = self()
    identity = identity(42, "I42")

    {:ok, cache} =
      start_cache(
        refresh_timeout_ms: 30_000,
        reader: fn _identity ->
          send(parent, {:reader_started, self()})

          receive do
            :finish -> {:ok, snapshot(identity, "late")}
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:reader_started, reader_pid}, 2_000
    ref = inflight_ref(cache, identity)
    send(cache, {:refresh_timeout, ref, 1})

    assert_receive {:ticket_detail_updated, state}, 2_000
    assert %State{generation: 1, health: :unavailable, failure: %Failure{kind: :timeout}} = state
    refute Process.alive?(reader_pid)

    send(cache, {ref, {:ok, snapshot(identity, "late")}})
    cache_barrier(cache)
    refute_receive {:ticket_detail_updated, %State{detail: %Snapshot{title: "late"}}}

    assert {:ok, %State{health: :unavailable, failure: %Failure{kind: :timeout}}} =
             TicketDetailCoordinator.current(cache, identity)
  end

  test "keeps last-known-good detail stale when a refresh task times out" do
    parent = self()
    identity = identity(42, "I42")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    {:ok, cache} =
      start_cache(
        freshness_ms: 1,
        refresh_timeout_ms: 30_000,
        clock_ms: fn -> Agent.get(clock, & &1) end,
        reader: fn _identity ->
          case Agent.get_and_update(attempts, fn attempt -> {attempt + 1, attempt + 1} end) do
            1 ->
              {:ok, snapshot(identity, "first")}

            2 ->
              send(parent, {:reader_started, self()})

              receive do
                :finish -> {:ok, snapshot(identity, "late")}
              end
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive(
      {:ticket_detail_updated, %State{generation: 1, health: :healthy, detail: %Snapshot{title: "first"}}},
      2_000
    )

    Agent.update(clock, fn _ -> 2 end)

    assert {:ok, %State{generation: 2, health: :stale, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.request(cache, identity)

    assert_receive {:reader_started, reader_pid}, 2_000
    ref = inflight_ref(cache, identity)
    send(cache, {:refresh_timeout, ref, 2})

    assert_receive {
                     :ticket_detail_updated,
                     %State{
                       generation: 2,
                       health: :stale,
                       detail: %Snapshot{title: "first"},
                       failure: %Failure{kind: :timeout}
                     }
                   },
                   2_000

    refute Process.alive?(reader_pid)
    send(cache, {ref, {:ok, snapshot(identity, "late")}})
    cache_barrier(cache)
    refute_receive {:ticket_detail_updated, %State{detail: %Snapshot{title: "late"}}}
  end

  test "keeps last-known-good detail when a timeout races a task-supervisor restart" do
    parent = self()
    identity = identity(42, "I42")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok, cache} =
      start_cache(
        freshness_ms: 1,
        task_supervisor: task_supervisor,
        clock_ms: fn -> Agent.get(clock, & &1) end,
        reader: fn _identity ->
          case Agent.get_and_update(attempts, fn attempt -> {attempt + 1, attempt + 1} end) do
            1 ->
              {:ok, snapshot(identity, "first")}

            2 ->
              send(parent, {:reader_started, self()})

              receive do
                :finish -> {:ok, snapshot(identity, "late")}
              end
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive(
      {:ticket_detail_updated, %State{generation: 1, health: :healthy, detail: %Snapshot{title: "first"}}},
      2_000
    )

    Agent.update(clock, fn _ -> 2 end)

    assert {:ok, %State{generation: 2, health: :stale, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.request(cache, identity)

    assert_receive {:reader_started, reader_pid}, 2_000
    ref = inflight_ref(cache, identity)
    {:ok, stale_supervisor} = Task.Supervisor.start_link()
    :ok = GenServer.stop(stale_supervisor)
    :sys.replace_state(cache, &Map.put(&1, :task_supervisor, stale_supervisor))
    send(cache, {:refresh_timeout, ref, 2})

    assert_receive {
                     :ticket_detail_updated,
                     %State{
                       generation: 2,
                       health: :stale,
                       detail: %Snapshot{title: "first"},
                       failure: %Failure{kind: :timeout}
                     }
                   },
                   2_000

    assert Process.alive?(cache)
    reader_ref = Process.monitor(reader_pid)
    send(reader_pid, :finish)
    assert_receive {:DOWN, ^reader_ref, :process, ^reader_pid, _reason}, 2_000
    cache_barrier(cache)
    refute_receive {:ticket_detail_updated, %State{detail: %Snapshot{title: "late"}}}
  end

  test "ignores a delayed completion from an older generation" do
    parent = self()
    identity = identity(42, "I42")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    {:ok, cache} =
      start_cache(
        freshness_ms: 10,
        clock_ms: fn -> Agent.get(clock, & &1) end,
        reader: fn _identity ->
          attempt = Agent.get_and_update(attempts, fn value -> {value + 1, value + 1} end)
          send(parent, {:reader_started, attempt, self()})

          receive do
            :finish -> {:ok, snapshot(identity, if(attempt == 1, do: "first", else: "second"))}
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:reader_started, 1, first_reader}, 2_000
    first_ref = inflight_ref(cache, identity)
    send(first_reader, :finish)
    assert_receive {:ticket_detail_updated, %State{generation: 1, detail: %Snapshot{title: "first"}}}, 2_000

    Agent.update(clock, fn _ -> 11 end)
    assert {:ok, %State{generation: 2, health: :stale}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:reader_started, 2, second_reader}, 2_000

    send(cache, {first_ref, {:ok, snapshot(identity, "late")}})
    cache_barrier(cache)
    refute_receive {:ticket_detail_updated, %State{detail: %Snapshot{title: "late"}}}

    send(second_reader, :finish)
    assert_receive {:ticket_detail_updated, %State{generation: 2, detail: %Snapshot{title: "second"}}}, 2_000
  end

  test "restart loses in-memory detail until a new demand succeeds" do
    identity = identity(42, "I42")
    {:ok, cache} = start_cache(reader: fn identity -> {:ok, snapshot(identity, "first")} end)

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, identity: ^identity}}, 2_000
    :ok = GenServer.stop(cache)

    {:ok, restarted} = start_cache(reader: fn _identity -> flunk("current must not fetch") end)

    assert {:ok, %State{health: :unavailable, detail: nil, generation: :unknown}} =
             TicketDetailCoordinator.current(restarted, identity)
  end

  test "abnormal supervised restart tells existing subscribers to clear detail" do
    identity = identity(42, "I42")
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    {:ok, epochs} = Agent.start_link(fn -> 0 end)

    cache_options = [
      name: nil,
      configured_repo: @configured,
      task_supervisor: task_supervisor,
      configuration_subscriber: fn _pid -> :ok end,
      reset_epoch: fn -> Agent.get_and_update(epochs, fn epoch -> {epoch + 1, epoch + 1} end) end,
      reader: fn requested_identity -> {:ok, snapshot(requested_identity, "first")} end
    ]

    {:ok, supervisor} = Supervisor.start_link([{TicketDetailCoordinator, cache_options}], strategy: :one_for_one)
    cache = cache_child(supervisor)

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, identity: ^identity}}, 2_000

    Process.exit(cache, :kill)

    assert_receive {:ticket_detail_coordinator_reset, 2}, 2_000
    restarted = cache_child(supervisor)
    refute restarted == cache

    assert {:ok, %State{health: :unavailable, detail: nil, generation: :unknown}} =
             TicketDetailCoordinator.current(restarted, identity)
  end

  test "abnormal restart kills owned in-flight reads before replacement demand" do
    parent = self()
    identity = identity(42, "I42")
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    cache_options = [
      name: nil,
      configured_repo: @configured,
      task_supervisor: task_supervisor,
      configuration_subscriber: fn _pid -> :ok end,
      reader: fn _identity ->
        attempt = Agent.get_and_update(attempts, fn value -> {value + 1, value + 1} end)
        send(parent, {:reader_started, attempt, self()})

        receive do
          :finish -> {:ok, snapshot(identity, "generation-#{attempt}")}
        end
      end
    ]

    {:ok, supervisor} = Supervisor.start_link([{TicketDetailCoordinator, cache_options}], strategy: :one_for_one)
    cache = cache_child(supervisor)

    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:reader_started, 1, old_reader}, 2_000
    old_reader_ref = Process.monitor(old_reader)

    Process.exit(cache, :kill)
    assert_receive {:DOWN, ^old_reader_ref, :process, ^old_reader, _reason}, 2_000

    restarted = cache_child(supervisor)
    refute restarted == cache
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(restarted, identity)
    assert_receive {:reader_started, 2, new_reader}, 2_000
    refute Process.alive?(old_reader)
    send(new_reader, :finish)
  end

  test "does not let direct startup options exceed cache hard bounds" do
    {:ok, cache} =
      start_cache(
        freshness_ms: 300_001,
        refresh_timeout_ms: 30_001,
        max_entries: 101,
        max_description_bytes: 16_385
      )

    assert %{
             freshness_ms: 30_000,
             refresh_timeout_ms: 30_000,
             max_entries: 32,
             max_description_bytes: 16_384
           } = :sys.get_state(cache)
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

  defp snapshot(identity, title) do
    %Snapshot{
      identity: identity,
      title: title,
      description: nil,
      lifecycle: Lifecycle.from_github("open", nil),
      url: "https://github.com/owner/repo/issues/#{identity.identifier}",
      created_at: ~U[2026-07-01 10:00:00Z],
      updated_at: ~U[2026-07-02 11:00:00Z],
      observed_at: ~U[2026-07-14 09:00:00Z]
    }
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

  defp inflight_ref(cache, identity) do
    %{entries: entries} = :sys.get_state(cache)

    %{inflight: %{ref: ref}} =
      Enum.find_value(entries, fn {_key, entry} -> if entry.identity == identity, do: entry end)

    ref
  end

  defp inflight_repository(cache, identity) do
    %{entries: entries} = :sys.get_state(cache)

    %{inflight: %{repository: repository}} =
      Enum.find_value(entries, fn {_key, entry} -> if entry.identity == identity, do: entry end)

    repository
  end

  defp subscribe_and_forward(cache, identity, parent) do
    spawn_link(fn ->
      :ok = TicketDetailCoordinator.subscribe(cache, identity)
      send(parent, {:detail_subscribed, self()})
      forward_detail_updates(parent)
    end)
  end

  defp cache_child(supervisor) do
    [{TicketDetailCoordinator, cache, :worker, _modules}] = Supervisor.which_children(supervisor)
    cache
  end

  defp cache_barrier(cache), do: :sys.get_state(cache)

  defp forward_detail_updates(parent) do
    receive do
      {:ticket_detail_updated, %State{} = state} ->
        send(parent, {:detail_update, self(), {:ticket_detail_updated, state}})
        forward_detail_updates(parent)
    end
  end
end
