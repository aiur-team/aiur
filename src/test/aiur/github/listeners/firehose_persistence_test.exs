defmodule Aiur.GitHub.Listeners.FirehosePersistenceTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.GitHub.Listeners
  alias Aiur.GitHub.Listeners.Firehose
  alias Aiur.Orchestrator.{FirehosePolling, State}
  alias Aiur.Workflow

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur"
    )

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    if is_nil(Process.whereis(Listeners)), do: start_supervised!(Listeners)
    Listeners.reset()
    :ok
  end

  describe "poll_github_firehose/2" do
    test "preserves stored etag on :not_modified response" do
      state = %Firehose{events_etag: "abc123"}
      parent = self()

      request_fun = fn request ->
        send(parent, {:firehose_request, request})
        {:ok, %{status: 304, headers: [{"ETag", "abc123"}, {"X-Poll-Interval", "60"}], body: ""}}
      end

      result = poll_firehose(state, request_fun: request_fun)

      assert result.events_etag == "abc123"
      assert_received {:firehose_request, %{etag: "abc123"}}
    end

    test "persistent merge-store failure retries finitely, degrades, alerts, and advances" do
      state = %Firehose{
        events_etag: "previous-etag",
        events_last_id: "last-seen"
      }

      event = %{
        "id" => "new-merge",
        "type" => "PullRequestEvent",
        "created_at" => "2026-07-12T18:00:00Z",
        "repo" => %{"name" => "owner/repo"},
        "payload" => %{
          "action" => "closed",
          "pull_request" => %{
            "number" => 42,
            "title" => "Merged feature",
            "body" => "Durable outcome",
            "html_url" => "https://github.com/owner/repo/pull/42",
            "merged" => true,
            "merged_at" => "2026-07-12T18:00:00Z",
            "head" => %{"ref" => "aiur/983-history", "sha" => "head-42"}
          }
        }
      }

      request_fun = fn request ->
        cond do
          String.contains?(Map.get(request, :url, ""), "/pulls/42/commits") ->
            {:ok, %{status: 200, body: [], headers: []}}

          Map.get(request, :etag) == "new-etag" ->
            {:ok, %{status: 304, headers: [{"ETag", "new-etag"}], body: ""}}

          Map.get(request, :etag) == "previous-etag" ->
            {:ok, %{status: 200, headers: [{"ETag", "new-etag"}], body: [event, %{"id" => "last-seen"}]}}
        end
      end

      {:ok, attempts} = Agent.start_link(fn -> 0 end)
      parent = self()

      opts = [
        request_fun: request_fun,
        recent_merge_fun: fn _merge ->
          Agent.update(attempts, &(&1 + 1))
          {:error, {:store_unavailable, {:unavailable, :read_only}}}
        end,
        recent_merge_alert_fun: fn topic, message, alert_opts ->
          send(parent, {:persistence_alert, topic, message, alert_opts})
          :ok
        end,
        boot_time: ~U[2026-07-12 17:00:00Z] |> DateTime.to_unix(),
        run_id: "current-run"
      ]

      first = poll_firehose(state, opts)
      second = poll_firehose(first, opts)

      assert first.events_etag == "previous-etag"
      assert first.events_last_id == "last-seen"
      assert second.events_etag == "previous-etag"
      assert second.events_last_id == "last-seen"

      third = poll_firehose(second, opts)

      health =
        Enum.reduce([first, second, third], %State{}, fn listener, state ->
          FirehosePolling.apply_outcome(state, listener.outcome)
        end)

      assert third.events_etag == "new-etag"
      assert third.events_last_id == "new-merge"
      # A local persistence failure is not lost connectivity: the catch-all no
      # longer stamps it `:transport`, so it lands `:unclassified` and backs off
      # at the conservative base rather than on the network escalation curve
      # (#2429 F2). The persistence alert below is the intended operator signal.
      assert health.github_connectivity[:recent_merge_store] == {:unclassified, 3}
      assert health.github_poll_delays[:recent_merge_store] == 1_000
      assert Agent.get(attempts, & &1) == 3

      assert_received {:persistence_alert, "recent_merge_store.persistence_failed", message, alert_opts}
      assert message =~ "read-only"
      assert alert_opts[:needs_attention]
      refute_received {:persistence_alert, _, _, _}

      fourth = poll_firehose(third, opts)
      health = FirehosePolling.apply_outcome(health, fourth.outcome)

      assert fourth.events_etag == "new-etag"
      assert fourth.events_last_id == "new-merge"
      assert health.github_connectivity[:recent_merge_store] == {:unclassified, 3}
      assert Agent.get(attempts, & &1) == 3
      refute_received {:persistence_alert, _, _, _}
    end
  end

  defp poll_firehose(state, opts) do
    :sys.replace_state(Firehose, fn _ -> state end)
    Listeners.poll_firehose(opts)
    :sys.get_state(Firehose)
  end
end
