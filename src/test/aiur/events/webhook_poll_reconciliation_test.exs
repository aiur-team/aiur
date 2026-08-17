defmodule Aiur.Events.WebhookPollReconciliationTest do
  @moduledoc """
  The poll sweep as a reconciliation pass over the webhook pipe (#2069).

  Two requirements pull against each other and the tension is the point:

    * a comment the webhook delivered must be processed **once**, not again by
      the next sweep, and
    * a comment whose delivery was **lost** must still be recovered — 9 of 100
      measured deliveries returned 502 during a daemon restart, GitHub retried
      none, and none arrived later.

  A blanket "skip polling when the repo is webhook-backed" satisfies the first
  and silently loses the second. Suppressing per *resource identity* satisfies
  both: the sweep always runs and always reads, and only the individual comments
  some pipe already processed are held back.
  """

  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, GithubCommentsPoller, GithubWebhook}
  alias Aiur.GitHub.ResourceStore

  @repo "owner/repo"
  @topic "ticket.42.issue.commented"

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: @repo)

    dir = Path.join(System.tmp_dir!(), "aiur-reconciliation-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    store_path = Path.join(dir, "github_resources.json")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_token)
      Application.delete_env(:aiur, :github_resource_store_path)

      if Process.whereis(ResourceStore) == nil do
        Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
      end

      ResourceStore.reset()
      File.rm_rf(dir)
    end)

    {:ok, store_path: store_path}
  end

  describe "a comment the webhook delivered" do
    # Acceptance criterion 3. The sweep still reads the comment back — that read
    # is what makes criterion 4 possible — but it must not publish it a second
    # time and wake the agent twice for one human comment.
    test "is published once by the delivery and not again by the sweep" do
      :ok = Exchange.subscribe(@topic)

      assert %{status: :published, published: [@topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(9001, "review this"), repo: @repo)

      assert %{comment: %{"id" => 9001}} = await_event(@topic)

      # The sweep reads the very same comment back from GitHub.
      {calls, result} = sweep([comment(9001, "review this")])

      assert {:ok, %{count: 0}} = result
      # The read still happened: this is reconciliation, not suppression of the
      # sweep itself.
      assert length(calls) == 1
      refute_event(@topic)
    end

    # The in-memory replay window empties on every daemon restart, which is
    # exactly when this matters: the 502s that lost deliveries were measured
    # *during* a restart, so the sweep that runs right after one is the sweep
    # most likely to re-read a comment the pre-restart daemon already handled.
    test "stays suppressed across a restart of the in-memory replay window" do
      :ok = Exchange.subscribe(@topic)

      assert %{status: :published, published: [@topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(9010, "before the restart"), repo: @repo)

      assert %{comment: %{"id" => 9010}} = await_event(@topic)

      clear_replay_window()

      {_calls, result} = sweep([comment(9010, "before the restart")])

      assert {:ok, %{count: 0}} = result
      refute_event(@topic)
    end
  end

  describe "a comment whose delivery was lost" do
    # Acceptance criterion 4. Nothing marked this comment, so nothing suppresses
    # it. This is the case a blanket skip-when-webhook-backed would drop on the
    # floor, and the 9% measured loss rate is why it cannot be dropped.
    test "is recovered by the next sweep" do
      :ok = Exchange.subscribe(@topic)

      {_calls, result} = sweep([comment(9002, "the 502'd one")])

      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"id" => 9002}} = await_event(@topic)
    end

    # The hazard a timestamp watermark would have: comment 9004 is delivered and
    # marks the newest position, while the older 9003 was lost. "Anything newer
    # than the last thing I processed" would silently discard 9003 forever.
    # Identity suppression cannot make that mistake.
    test "is recovered even when a newer sibling was delivered successfully" do
      :ok = Exchange.subscribe(@topic)

      assert %{status: :published, published: [@topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(9004, "newer, delivered"), repo: @repo)

      assert %{comment: %{"id" => 9004}} = await_event(@topic)

      {_calls, result} =
        sweep([
          comment(9003, "older, lost", "2026-06-24T11:30:00Z"),
          comment(9004, "newer, delivered", "2026-06-24T11:45:00Z")
        ])

      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"id" => 9003}} = await_event(@topic)
      refute_event(@topic)
    end
  end

  describe "cost" do
    # Acceptance criterion 1. A steady-state cycle over unchanged resources
    # should cost nothing, not merely less: a 304 does not count against
    # GitHub's primary REST limit. The assertion is on the request the poller
    # actually sends, because that is the thing that either is or is not
    # conditional.
    test "an unchanged sweep revalidates with If-None-Match and publishes nothing" do
      :ok = Exchange.subscribe(@topic)

      # First sweep has no validator to send, so it is a full-price read.
      {first_calls, _result} = sweep([comment(9005, "first read")], etag: ~s("v1"))
      assert [request] = first_calls
      refute Map.has_key?(request, :etag)
      assert %{comment: %{"id" => 9005}} = await_event(@topic)

      # Second sweep sends it back and GitHub answers 304 — free.
      {second_calls, result} = sweep(:not_modified)

      assert [%{etag: ~s("v1")}] = Enum.map(second_calls, &Map.take(&1, [:etag]))
      assert {:ok, %{count: 0, errors: []}} = result
      refute_event(@topic)
    end

    # Acceptance criterion 5, at the level that matters operationally: the
    # validator has to come back after the process holding it dies, or the first
    # sweep of every boot is a full-price read of every watched ticket.
    test "the validator survives a restart of the store", %{store_path: store_path} do
      # Point the store at a real file for this case: with no resolvable state
      # directory it runs in memory, which would make the restart trivially
      # pass nothing rather than prove the checkpoint round-trip.
      restart_store!(store_path)

      resource = ResourceStore.key_for_repo(:issue_comments, @repo, "42")
      ResourceStore.put_etag(resource, ~s("survives"))
      assert :ok = ResourceStore.flush()
      assert File.exists?(store_path)

      restart_store!(store_path)

      {calls, _result} = sweep(:not_modified)

      assert [%{etag: ~s("survives")}] = Enum.map(calls, &Map.take(&1, [:etag]))
    end
  end

  describe "a repo with no webhook" do
    # Acceptance criterion 6. Nothing about this path is conditional on webhook
    # transport, which is the point: an unproven repo never had a delivery, so
    # nothing is ever marked, so nothing is ever suppressed. It polls and
    # publishes exactly as it did before this store existed.
    test "publishes everything the sweep reads, exactly as before" do
      :ok = Exchange.subscribe(@topic)

      {_calls, result} =
        sweep([
          comment(9006, "one", "2026-06-24T11:30:00Z"),
          comment(9007, "two", "2026-06-24T11:45:00Z")
        ])

      assert {:ok, %{count: 2}} = result
      assert %{comment: %{"id" => 9006}} = await_event(@topic)
      assert %{comment: %{"id" => 9007}} = await_event(@topic)
    end
  end

  # -- helpers ---------------------------------------------------------------

  # Runs one comment-poll cycle against a recording request stub and returns
  # {requests, result}. `open_pull_request: nil` keeps the cycle to the issue
  # comment read so the request count means what it says.
  defp sweep(response, opts \\ []) do
    {:ok, recorder} = Agent.start_link(fn -> [] end)
    etag = Keyword.get(opts, :etag, ~s("v1"))

    request_fun = fn request ->
      Agent.update(recorder, &(&1 ++ [request]))

      case response do
        :not_modified ->
          {:ok, %{status: 304, headers: [{"etag", etag}]}}

        comments when is_list(comments) ->
          {:ok, %{status: 200, body: comments, headers: [{"etag", etag}]}}
      end
    end

    result =
      GithubCommentsPoller.poll(["42"],
        since: "2026-06-24T11:00:00Z",
        repo: @repo,
        request_fun: request_fun,
        comment_batch: %{"42" => %{open_pull_request: nil}}
      )

    calls = Agent.get(recorder, & &1)
    Agent.stop(recorder)

    {calls, result}
  end

  defp delivery(id, body) do
    %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "issue" => %{"number" => 42},
      "comment" => comment(id, body),
      "sender" => %{"login" => "its-everdred"}
    }
  end

  defp comment(id, body, updated_at \\ "2026-06-24T12:00:00Z") do
    %{
      "id" => id,
      "body" => body,
      "created_at" => updated_at,
      "updated_at" => updated_at,
      "html_url" => "https://example.test/comments/#{id}",
      "user" => %{"login" => "its-everdred"}
    }
  end

  # Empties only the volatile replay window, leaving the durable resource marks
  # in place — the state a daemon restart actually produces.
  defp clear_replay_window do
    case :ets.whereis(Aiur.Events.Publisher.Dedup) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end
  end

  defp restart_store!(path) do
    pid = Process.whereis(ResourceStore)
    ref = Process.monitor(pid)
    Supervisor.terminate_child(Aiur.Supervisor, ResourceStore)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> flunk("ResourceStore did not stop")
    end

    Application.put_env(:aiur, :github_resource_store_path, path)
    {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
    :ok
  end

  defp await_event(topic) do
    receive do
      {:event, %{topic: ^topic} = event} -> event
    after
      1_000 -> flunk("no event published on #{topic}")
    end
  end

  defp refute_event(topic) do
    receive do
      {:event, %{topic: ^topic} = event} -> flunk("unexpected second publish on #{topic}: #{inspect(event)}")
    after
      200 -> :ok
    end
  end
end
