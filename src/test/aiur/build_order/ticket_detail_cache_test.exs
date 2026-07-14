defmodule Aiur.BuildOrder.TicketDetailCacheTest do
  use ExUnit.Case, async: false

  alias Aiur.{BuildOrder.Lifecycle, BuildOrder.TicketDetail, TrackerIdentity}
  alias Aiur.BuildOrder.TicketDetail.{Failure, Snapshot, State}
  alias Aiur.BuildOrder.TicketDetailCache

  @configured {"owner", "repo"}

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

    assert :ok = TicketDetailCache.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable, generation: 1}} = TicketDetailCache.request(cache, identity)
    assert_receive {:reader_started, reader_pid}

    for _ <- 1..3 do
      assert {:ok, %State{health: :unavailable, generation: 1}} = TicketDetailCache.request(cache, identity)
    end

    refute_receive {:reader_started, _reader_pid}
    send(reader_pid, :finish)

    assert_receive {:ticket_detail_updated, %State{health: :healthy, generation: 1, detail: %Snapshot{title: "first"}}}

    assert {:ok, %State{health: :healthy, generation: 1, detail: %Snapshot{title: "first"}}} =
             TicketDetailCache.current(cache, identity)
  end

  test "rejects another repository before cache admission or reader invocation" do
    foreign = identity(42, "Foreign42", {"other", "repo"})

    {:ok, cache} =
      start_cache(reader: fn _identity -> flunk("reader must not be invoked") end)

    assert {:error, %Failure{kind: :nonfetchable_repository}} = TicketDetailCache.request(cache, foreign)
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

    assert :ok = TicketDetailCache.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCache.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, detail: %Snapshot{title: "first"}}}

    Agent.update(clock, fn _ -> 11 end)

    assert {:ok, %State{health: :stale, detail: %Snapshot{title: "first"}}} =
             TicketDetailCache.request(cache, identity)

    assert_receive {
      :ticket_detail_updated,
      %State{
        health: :stale,
        detail: %Snapshot{title: "first"},
        failure: %Failure{kind: :timeout}
      }
    }
  end

  test "reports a cold failure as unavailable rather than fabricating detail" do
    identity = identity(42, "I42")
    {:ok, cache} = start_cache(reader: fn _identity -> {:error, %Failure{kind: :not_found}} end)

    assert :ok = TicketDetailCache.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable, detail: nil}} = TicketDetailCache.request(cache, identity)

    assert_receive {
      :ticket_detail_updated,
      %State{health: :unavailable, detail: nil, failure: %Failure{kind: :not_found}}
    }
  end

  test "recovers from a cold failure only after a later successful demand" do
    identity = identity(42, "I42")
    {:ok, results} = Agent.start_link(fn -> [{:error, %Failure{kind: :timeout}}, {:ok, snapshot(identity, "recovered")}] end)

    {:ok, cache} =
      start_cache(reader: fn _identity -> Agent.get_and_update(results, fn [result | rest] -> {result, rest} end) end)

    assert :ok = TicketDetailCache.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCache.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{generation: 1, health: :unavailable, detail: nil}}

    assert {:ok, %State{generation: 2, health: :unavailable}} = TicketDetailCache.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{generation: 2, health: :healthy, detail: %Snapshot{title: "recovered"}}}
  end

  test "bounds retention by evicting completed least-recently-used entries" do
    first = identity(1, "I1")
    second = identity(2, "I2")

    {:ok, cache} =
      start_cache(max_entries: 1, reader: fn identity -> {:ok, snapshot(identity, identity.identifier)} end)

    assert :ok = TicketDetailCache.subscribe(cache, first)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCache.request(cache, first)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, identity: ^first}}

    assert :ok = TicketDetailCache.subscribe(cache, second)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCache.request(cache, second)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, identity: ^second}}
    assert {:ok, %State{health: :unavailable, detail: nil}} = TicketDetailCache.current(cache, first)
  end

  test "notifies every subscriber before evicting a completed entry" do
    parent = self()
    first = identity(1, "I1")
    second = identity(2, "I2")

    {:ok, cache} =
      start_cache(max_entries: 1, reader: fn identity -> {:ok, snapshot(identity, identity.identifier)} end)

    first_subscriber = subscribe_and_forward(cache, first, parent)
    second_subscriber = subscribe_and_forward(cache, first, parent)

    assert_receive {:detail_subscribed, ^first_subscriber}
    assert_receive {:detail_subscribed, ^second_subscriber}
    assert {:ok, %State{health: :unavailable}} = TicketDetailCache.request(cache, first)

    assert_receive {:detail_update, ^first_subscriber, {:ticket_detail_updated, first_update}}
    assert %State{generation: 1, health: :healthy, identity: ^first} = first_update

    assert_receive {:detail_update, ^second_subscriber, {:ticket_detail_updated, second_update}}
    assert %State{generation: 1, health: :healthy, identity: ^first} = second_update

    assert {:ok, %State{health: :unavailable}} = TicketDetailCache.request(cache, second)

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
    }

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
    }

    assert {:ok, %State{health: :unavailable, detail: nil}} = TicketDetailCache.current(cache, first)
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

    assert {:ok, %State{health: :unavailable}} = TicketDetailCache.request(cache, first)
    assert_receive {:reader_started, reader_pid}
    assert {:error, %Failure{kind: :capacity}} = TicketDetailCache.request(cache, second)
    send(reader_pid, :finish)
  end

  test "cannot publish a snapshot from another ticket identity" do
    identity = identity(42, "I42")
    other_identity = identity(43, "I43")

    {:ok, cache} =
      start_cache(reader: fn _identity -> {:ok, snapshot(other_identity, "wrong ticket")} end)

    assert :ok = TicketDetailCache.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCache.request(cache, identity)

    assert_receive {
      :ticket_detail_updated,
      %State{
        health: :unavailable,
        detail: nil,
        failure: %Failure{kind: :provider_identity_mismatch}
      }
    }
  end

  test "publishes structured credential-sanitized detail without the raw provider body" do
    identity = identity(42, "I42")

    body =
      "Authorization: Bearer not-a-known-prefix-secret\n" <>
        "Cookie: private-session-cookie\n" <>
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
        "/etc/passwd /opt/aiur/private.env"

    {:ok, cache} =
      start_cache(
        reader: fn requested_identity ->
          TicketDetail.fetch(requested_identity,
            configured_repo: @configured,
            request_fun: fn _request ->
              {:ok, %{status: 200, body: detail_issue(requested_identity, body)}}
            end
          )
        end
      )

    assert :ok = TicketDetailCache.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCache.request(cache, identity)

    assert_receive {:ticket_detail_updated, %State{detail: %Snapshot{description: description}}}
    assert description =~ "[REDACTED:credential]"
    refute description =~ "not-a-known-prefix-secret"
    refute description =~ "private-session-cookie"
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

    assert :ok = TicketDetailCache.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCache.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{generation: 1, health: :healthy, detail: %Snapshot{title: "first"}}}

    :ok = GenServer.stop(failed_supervisor)
    Agent.update(clock, fn _ -> 2 end)

    assert {:ok, %State{generation: 2, health: :stale, detail: %Snapshot{title: "first"}}} =
             TicketDetailCache.request(cache, identity)

    assert_receive {:ticket_detail_updated, outage_state}

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
             TicketDetailCache.request(cache, identity)

    assert_receive {:ticket_detail_updated,
                    %State{
                      generation: 3,
                      health: :healthy,
                      detail: %Snapshot{title: "recovered"}
                    }}
  end

  test "survives rejected task startup and recovers after a healthy supervisor is configured" do
    identity = identity(42, "I42")
    {:ok, rejecting_supervisor} = Task.Supervisor.start_link(max_children: 0)

    {:ok, cache} =
      start_cache(
        task_supervisor: rejecting_supervisor,
        reader: fn _identity -> {:ok, snapshot(identity, "recovered")} end
      )

    assert :ok = TicketDetailCache.subscribe(cache, identity)

    assert {:ok, %State{generation: 1, health: :unavailable, failure: %Failure{kind: :transport}}} =
             TicketDetailCache.request(cache, identity)

    assert_receive {:ticket_detail_updated,
                    %State{
                      generation: 1,
                      health: :unavailable,
                      failure: %Failure{kind: :transport}
                    }}

    assert Process.alive?(cache)
    {:ok, healthy_supervisor} = Task.Supervisor.start_link()
    :sys.replace_state(cache, &Map.put(&1, :task_supervisor, healthy_supervisor))

    assert {:ok, %State{generation: 2, health: :unavailable}} = TicketDetailCache.request(cache, identity)

    assert_receive {:ticket_detail_updated,
                    %State{
                      generation: 2,
                      health: :healthy,
                      detail: %Snapshot{title: "recovered"}
                    }}
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

    assert :ok = TicketDetailCache.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCache.request(cache, identity)
    assert_receive {:reader_started, reader_pid}
    ref = inflight_ref(cache, identity)
    send(cache, {:refresh_timeout, ref, 1})

    assert_receive {:ticket_detail_updated, state}
    assert %State{generation: 1, health: :unavailable, failure: %Failure{kind: :timeout}} = state
    refute Process.alive?(reader_pid)

    send(cache, {ref, {:ok, snapshot(identity, "late")}})
    refute_receive {:ticket_detail_updated, %State{detail: %Snapshot{title: "late"}}}

    assert {:ok, %State{health: :unavailable, failure: %Failure{kind: :timeout}}} =
             TicketDetailCache.current(cache, identity)
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

    assert :ok = TicketDetailCache.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCache.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{generation: 1, health: :healthy, detail: %Snapshot{title: "first"}}}

    Agent.update(clock, fn _ -> 2 end)

    assert {:ok, %State{generation: 2, health: :stale, detail: %Snapshot{title: "first"}}} =
             TicketDetailCache.request(cache, identity)

    assert_receive {:reader_started, reader_pid}
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
                   200

    refute Process.alive?(reader_pid)
    send(cache, {ref, {:ok, snapshot(identity, "late")}})
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

    assert :ok = TicketDetailCache.subscribe(cache, identity)
    assert {:ok, %State{generation: 1}} = TicketDetailCache.request(cache, identity)
    assert_receive {:reader_started, 1, first_reader}
    first_ref = inflight_ref(cache, identity)
    send(first_reader, :finish)
    assert_receive {:ticket_detail_updated, %State{generation: 1, detail: %Snapshot{title: "first"}}}

    Agent.update(clock, fn _ -> 11 end)
    assert {:ok, %State{generation: 2, health: :stale}} = TicketDetailCache.request(cache, identity)
    assert_receive {:reader_started, 2, second_reader}

    send(cache, {first_ref, {:ok, snapshot(identity, "late")}})
    refute_receive {:ticket_detail_updated, %State{detail: %Snapshot{title: "late"}}}

    send(second_reader, :finish)
    assert_receive {:ticket_detail_updated, %State{generation: 2, detail: %Snapshot{title: "second"}}}
  end

  test "restart loses in-memory detail until a new demand succeeds" do
    identity = identity(42, "I42")
    {:ok, cache} = start_cache(reader: fn identity -> {:ok, snapshot(identity, "first")} end)

    assert :ok = TicketDetailCache.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCache.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, identity: ^identity}}
    :ok = GenServer.stop(cache)

    {:ok, restarted} = start_cache(reader: fn _identity -> flunk("current must not fetch") end)

    assert {:ok, %State{health: :unavailable, detail: nil, generation: :unknown}} =
             TicketDetailCache.current(restarted, identity)
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

    TicketDetailCache.start_link(
      Keyword.merge(
        [
          name: nil,
          task_supervisor: task_supervisor,
          configured_repo: @configured,
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

  defp inflight_ref(cache, identity) do
    %{entries: entries} = :sys.get_state(cache)

    %{inflight: %{ref: ref}} =
      Enum.find_value(entries, fn {_key, entry} -> if entry.identity == identity, do: entry end)

    ref
  end

  defp subscribe_and_forward(cache, identity, parent) do
    spawn_link(fn ->
      :ok = TicketDetailCache.subscribe(cache, identity)
      send(parent, {:detail_subscribed, self()})
      forward_detail_updates(parent)
    end)
  end

  defp forward_detail_updates(parent) do
    receive do
      {:ticket_detail_updated, %State{} = state} ->
        send(parent, {:detail_update, self(), {:ticket_detail_updated, state}})
        forward_detail_updates(parent)
    end
  end
end
