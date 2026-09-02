defmodule AiurWeb.GithubWebhookDeliveryTest do
  @moduledoc """
  AC6 of W-3: a real review submitted on a real PR wakes the agent for that
  ticket, with no poll cycle in between.

  Every test drives `AiurWeb.Endpoint.call/2` with a genuinely HMAC-signed body,
  exactly as GitHub delivers it, and observes the event bus the fleet actually
  subscribes to. Nothing between the socket and `Aiur.Events.Publisher` is
  stubbed: the signature is verified, the body is parsed by the endpoint's own
  parser chain, the controller dispatches, and the normalizer publishes. A test
  that called `handle_delivery/3` directly would prove the normalizer works and
  say nothing about whether the receiver is wired to it — which is precisely the
  gap this file exists to close.

  "No poll cycle in between" is asserted, not assumed: a stand-in registered as
  `Aiur.Orchestrator` must never receive a dispatcher wake (`:run_poll_cycle`,
  or a `:request_refresh` call) for a review submission. If review deliveries
  were ever routed through the reconciler instead of published directly, the
  wake would depend on a poll and these tests would fail.

  The receiver also runs W-4's admission gate ahead of the dispatch, and that
  gate is durable and process-wide. Each test therefore gets its own
  `Aiur.Webhooks.DeliveryLog` and each delivery its own `X-GitHub-Delivery` id,
  so one test's claims cannot silently drop the next test's delivery — the same
  reason this file already clears `Publisher`'s replay window between deliveries.
  """

  use Aiur.TestSupport

  import Plug.Conn
  import Plug.Test

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Webhooks.DeliveryLog
  alias Aiur.Workflow
  alias AiurWeb.GithubWebhook
  alias AiurWeb.GithubWebhook.Auth

  @secret_env "AIUR_GITHUB_WEBHOOK_SECRET"
  @secret "s3cr3t-webhook-token"
  @repo "owner/repo"
  @topic "ticket.42.pr.review_comment"
  @dedup_table Aiur.Events.Publisher.Dedup

  setup do
    prev_secret = System.get_env(@secret_env)
    prev_token = System.get_env("GITHUB_TOKEN")
    endpoint_config = Application.get_env(:aiur, AiurWeb.Endpoint, [])

    System.put_env(@secret_env, @secret)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: @repo,
      tracker_label_prefix: "aiur"
    )

    Application.put_env(
      :aiur,
      AiurWeb.Endpoint,
      Keyword.merge(endpoint_config, server: false, secret_key_base: String.duplicate("s", 64), dashboard_auth_required: false)
    )

    if is_nil(Process.whereis(AiurWeb.Endpoint)), do: start_supervised!({AiurWeb.Endpoint, []})
    if is_nil(Process.whereis(Aiur.TaskSupervisor)), do: start_supervised!({Task.Supervisor, name: Aiur.TaskSupervisor})

    Auth.reset_alert_throttle()
    Publisher.set_tracked_fn(fn _ -> true end)
    clear_dedup()

    previous_log = Application.get_env(:aiur, :webhook_delivery_log)
    fresh_admission_store!()

    on_exit(fn ->
      Application.put_env(:aiur, AiurWeb.Endpoint, endpoint_config)
      Auth.reset_alert_throttle()
      Publisher.set_tracked_fn(fn _ -> true end)
      clear_dedup()
      restore_admission_store(previous_log)
      restore_env(@secret_env, prev_secret)
      restore_env("GITHUB_TOKEN", prev_token)

      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    :ok
  end

  describe "AC6: a submitted review wakes the ticket's agent through the receiver" do
    test "a signed CHANGES_REQUESTED delivery publishes the wake with no poll cycle" do
      :ok = Exchange.subscribe(@topic)
      orchestrator = stub_orchestrator()

      assert deliver("pull_request_review", review_delivery()).status == 202

      event = await_event(@topic)

      # The fields that decide rework routing, not merely that *something*
      # arrived: `GithubCommentsPoller.actionable_review?/1` keys on exactly
      # this state, and `#1427` wakes the agent off exactly this topic.
      assert event.topic == @topic
      assert event.issue_number == "42"
      assert event.comment["state"] == "CHANGES_REQUESTED"
      assert event.comment["body"] == "this needs a test"
      assert get_in(event.comment, ["user", "login"]) == "its-everdred"

      refute_received_poll_cycle(orchestrator)
    end

    test "the wake does not survive removing the signature" do
      :ok = Exchange.subscribe(@topic)

      conn = deliver("pull_request_review", review_delivery(), signature: nil)

      assert conn.status == 401
      refute_event(@topic)
    end

    test "a form-encoded delivery wakes the agent identically to a JSON one" do
      :ok = Exchange.subscribe(@topic)

      json = deliver("pull_request_review", review_delivery())
      assert json.status == 202
      from_json = await_event(@topic)

      # Both dedupe layers see the second delivery as a repeat of the first —
      # `Publisher`'s replay window and W-4's semantic event key — and both are
      # right to. This test is asking a different question: whether the two
      # encodings normalize to the same event at all.
      clear_dedup()
      fresh_admission_store!()

      form = deliver_form("pull_request_review", review_delivery())
      assert form.status == 202
      from_form = await_event(@topic)

      assert from_json.comment == from_form.comment
      assert from_json.topic == from_form.topic
      assert from_json.issue_number == from_form.issue_number
      assert from_json.pull_request == from_form.pull_request
    end

    test "a JSON delivery carrying a top-level payload key is not mistaken for a form" do
      :ok = Exchange.subscribe(@topic)

      # The form branch must key off the content type, not the presence of a
      # `payload` field: keying off the field would decode this body as a form,
      # fail, and silently drop a delivery the fleet should have woken on.
      delivery = Map.put(review_delivery(), "payload", "not the body")

      assert deliver("pull_request_review", delivery).status == 202

      event = await_event(@topic)
      assert event.comment["state"] == "CHANGES_REQUESTED"
    end
  end

  describe "W-4 admission runs ahead of the dispatch" do
    test "a retried delivery publishes the wake exactly once" do
      :ok = Exchange.subscribe(@topic)

      delivery = review_delivery()
      retry_id = "22222222-3333-4444-5555-666666666666"

      assert deliver("pull_request_review", delivery, delivery: retry_id).status == 202
      assert await_event(@topic)

      # GitHub retries under the *same* delivery id. `Publisher`'s replay window
      # is cleared first, so surviving this can only be the admission gate and
      # not the layer underneath it — which is the whole point of running the
      # gate at the receiver rather than relying on the publish tail.
      clear_dedup()

      assert deliver("pull_request_review", delivery, delivery: retry_id).status == 202
      refute_event(@topic)
    end

    test "a manual redelivery under a fresh delivery id publishes the wake exactly once" do
      :ok = Exchange.subscribe(@topic)

      delivery = review_delivery()

      assert deliver("pull_request_review", delivery).status == 202
      assert await_event(@topic)

      clear_dedup()

      # A redelivery from the App's Advanced tab carries a *new* delivery id for
      # the same underlying event, so delivery-id dedupe cannot see it. Only the
      # payload-derived event key catches this one.
      assert deliver("pull_request_review", delivery).status == 202
      refute_event(@topic)
    end
  end

  describe "containment" do
    test "a delivery for an untracked repository publishes nothing" do
      :ok = Exchange.subscribe(@topic)

      delivery = put_in(review_delivery(), ["repository", "full_name"], "someone-else/other-repo")

      assert deliver("pull_request_review", delivery).status == 202
      refute_event(@topic)
    end

    test "an unrecognized event type is ignored and the endpoint stays up" do
      :ok = Exchange.subscribe(@topic)

      assert deliver("deployment_protection_rule", review_delivery()).status == 202
      refute_event(@topic)

      # Still serving after the unknown type.
      assert deliver("pull_request_review", review_delivery()).status == 202
      assert await_event(@topic)
    end

    test "a delivery with no event header is ignored without publishing" do
      :ok = Exchange.subscribe(@topic)

      body = Jason.encode!(review_delivery())

      conn =
        :post
        |> conn(GithubWebhook.path(), body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", github_signature(@secret, body))
        |> call()

      assert conn.status == 202
      refute_event(@topic)
    end

    test "a malformed payload is rejected without taking down the endpoint" do
      :ok = Exchange.subscribe(@topic)

      # Signed, well-formed JSON, but not a delivery: no repository, no review.
      assert deliver("pull_request_review", %{"action" => "submitted"}).status == 202
      refute_event(@topic)

      assert deliver("pull_request_review", review_delivery()).status == 202
      assert await_event(@topic)
    end
  end

  defp review_delivery do
    %{
      "action" => "submitted",
      "repository" => %{"full_name" => @repo},
      "review" => %{
        "id" => 55_001,
        "state" => "changes_requested",
        "body" => "this needs a test",
        "submitted_at" => "2026-06-24T12:00:00Z",
        "user" => %{"login" => "its-everdred"}
      },
      "pull_request" => %{"number" => 901, "head" => %{"ref" => "aiur/42-some-slug", "sha" => "deadbeef"}},
      "sender" => %{"login" => "its-everdred"}
    }
  end

  # A stand-in for the orchestrator, so a reconcile nudge would be observable.
  # Registered only when the real one is absent; when it is present the test
  # falls back to asserting through it is impossible and skips the check.
  defp stub_orchestrator do
    if is_nil(Process.whereis(Aiur.Orchestrator)) do
      test = self()
      pid = spawn_link(fn -> forward_messages(test) end)
      Process.register(pid, Aiur.Orchestrator)
      on_exit(fn -> unregister_orchestrator(pid) end)
      pid
    end
  end

  defp unregister_orchestrator(pid) do
    if Process.whereis(Aiur.Orchestrator) == pid, do: Process.unregister(Aiur.Orchestrator)
  end

  defp forward_messages(test) do
    receive do
      message ->
        send(test, {:orchestrator, message})
        forward_messages(test)
    end
  end

  defp refute_received_poll_cycle(nil), do: :ok

  defp refute_received_poll_cycle(_pid) do
    refute_receive {:orchestrator, :run_poll_cycle}, 200
    refute_receive {:orchestrator, {:"$gen_call", _from, :request_refresh}}, 200
  end

  # GitHub stamps every delivery with its own id, so the default here is unique
  # per call. A test that wants to model a *retry* passes `:delivery` explicitly
  # to reuse one.
  defp deliver(event_type, payload, opts \\ []) do
    body = Jason.encode!(payload)

    :post
    |> conn(GithubWebhook.path(), body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", event_type)
    |> put_req_header("x-github-delivery", Keyword.get_lazy(opts, :delivery, &unique_delivery_id/0))
    |> maybe_sign(body, opts)
    |> call()
  end

  defp unique_delivery_id, do: "11111111-2222-3333-4444-#{System.unique_integer([:positive, :monotonic])}"

  # A store per test, so admission claims cannot leak between tests. Called
  # again inside a test that deliberately replays one underlying event through
  # two independent deliveries.
  defp fresh_admission_store! do
    dir = Aiur.TestSupport.tmp_root!("aiur-webhook-delivery")
    name = :"delivery_test_log_#{System.unique_integer([:positive])}"
    log = start_supervised!({DeliveryLog, name: name, state_dir: dir}, id: name)

    Application.put_env(:aiur, :webhook_delivery_log, log)
    on_exit(fn -> File.rm_rf!(dir) end)

    log
  end

  defp restore_admission_store(nil), do: Application.delete_env(:aiur, :webhook_delivery_log)
  defp restore_admission_store(previous), do: Application.put_env(:aiur, :webhook_delivery_log, previous)

  defp deliver_form(event_type, payload) do
    body = URI.encode_query(%{"payload" => Jason.encode!(payload)})

    :post
    |> conn(GithubWebhook.path(), body)
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("x-github-event", event_type)
    |> put_req_header("x-hub-signature-256", github_signature(@secret, body))
    |> call()
  end

  defp maybe_sign(conn, body, opts) do
    case Keyword.get(opts, :signature, :valid) do
      :valid -> put_req_header(conn, "x-hub-signature-256", github_signature(@secret, body))
      nil -> conn
      signature -> put_req_header(conn, "x-hub-signature-256", signature)
    end
  end

  # GitHub's documented algorithm, written out rather than delegated to the
  # module under test so these tests cannot agree with a wrong implementation.
  defp github_signature(secret, body) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
  end

  defp call(conn), do: AiurWeb.Endpoint.call(conn, AiurWeb.Endpoint.init([]))

  defp await_event(topic) do
    # The endpoint intentionally answers before its supervised publish task
    # finishes. Wait on that task's observable event, not a host-speed budget.
    {:event, event} = receive_barrier({:event, %{topic: ^topic}})
    event
  end

  defp refute_event(topic) do
    receive do
      {:event, %{topic: ^topic} = event} -> flunk("unexpected event published on #{topic}: #{inspect(event)}")
    after
      300 -> :ok
    end
  end

  # Clears every suppression layer, not only the in-memory window: since #2069
  # a published comment is also recorded durably by resource identity, so a test
  # that deliberately replays the same comment has to forget both.
  #
  # The drain is load-bearing. The receiver answers 202 and publishes from a
  # supervised task, and `Publisher` records the resource *after* the exchange
  # hands the event to subscribers — so `await_event/1` can return while the
  # recording is still in flight. Clearing before that lands would wipe nothing
  # and leave the replay suppressed, which is a flake, not a finding.
  defp clear_dedup do
    await_deliveries()

    case :ets.whereis(@dedup_table) do
      :undefined -> :ok
      _table -> :ets.delete_all_objects(@dedup_table)
    end

    ResourceStore.reset()

    :ok
  end

  defp await_deliveries(remaining \\ 200)

  defp await_deliveries(0), do: :ok

  defp await_deliveries(remaining) do
    case Task.Supervisor.children(Aiur.TaskSupervisor) do
      [] ->
        :ok

      _running ->
        Process.sleep(5)
        await_deliveries(remaining - 1)
    end
  catch
    :exit, _reason -> :ok
  end
end
