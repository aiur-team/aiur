defmodule AiurWeb.GithubWebhookAdmissionTest do
  @moduledoc """
  Logging, payload size, wiring, delivery admission and the signature module
  for the webhook receiver. Split out of `github_webhook_test.exs`, whose
  moduledoc states why these go through `AiurWeb.Endpoint`.
  """

  use Aiur.TestSupport.GithubWebhookReceiverCase

  alias Aiur.Webhooks.DeliveryLog
  alias AiurWeb.GithubWebhook
  alias AiurWeb.GithubWebhook.{BodyReader, Signature}

  @secret "s3cr3t-webhook-token"
  @payload ~s({"action":"submitted","number":1676})

  describe "logging" do
    test "never logs the signature or the payload" do
      signature = github_signature(@secret, @payload)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          @payload
          |> build_conn(signature: signature)
          |> put_req_header("x-github-delivery", "d3adbeef-1676")
          |> put_req_header("x-github-event", "pull_request_review")
          |> call()
        end)

      assert log =~ "d3adbeef-1676"
      assert log =~ "pull_request_review"
      refute log =~ signature
      refute log =~ "submitted"
    end

    test "records delivery id and event type for accepted and rejected deliveries" do
      accepted =
        ExUnit.CaptureLog.capture_log(fn ->
          @payload
          |> build_conn(signature: github_signature(@secret, @payload))
          |> put_req_header("x-github-delivery", "delivery-accepted")
          |> put_req_header("x-github-event", "issues")
          |> call()
        end)

      assert accepted =~ "accepted delivery=delivery-accepted event=issues"

      rejected =
        ExUnit.CaptureLog.capture_log(fn ->
          @payload
          |> build_conn(signature: github_signature("nope", @payload))
          |> put_req_header("x-github-delivery", "delivery-rejected")
          |> put_req_header("x-github-event", "issues")
          |> call()
        end)

      assert rejected =~ "rejected delivery=delivery-rejected event=issues"
      assert rejected =~ "reason=signature_mismatch"
    end

    test "sanitizes attacker-controlled header values before logging them" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          @payload
          |> build_conn(signature: nil)
          |> put_req_header("x-github-delivery", "abc\r\nfake-log-line")
          |> put_req_header("x-github-event", String.duplicate("e", 500))
          |> call()
        end)

      refute log =~ "abc\r\nfake-log-line"
      assert log =~ "abc??fake-log-line"
      refute log =~ String.duplicate("e", 200)
    end

    test "falls back to a placeholder when a header sanitizes to nothing" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          @payload
          |> build_conn(signature: nil)
          |> put_req_header("x-github-delivery", "")
          |> call()
        end)

      assert log =~ "delivery=unknown event=unknown"
    end
  end

  describe "payload size" do
    test "verifies and acknowledges a payload at the documented size limit inside GitHub's timeout" do
      body = payload_of_exactly(GithubWebhook.max_body_bytes())
      assert byte_size(body) == GithubWebhook.max_body_bytes()

      {microseconds, conn} = :timer.tc(fn -> deliver(body, signature: github_signature(@secret, body)) end)

      assert conn.status == 202
      assert microseconds < 10_000_000, "handler took #{div(microseconds, 1000)}ms, past GitHub's 10s delivery timeout"
    end

    test "refuses to verify a truncated read of an oversized body" do
      oversized = :binary.copy("a", GithubWebhook.max_body_bytes() + 1)

      conn = conn(:post, GithubWebhook.path(), oversized)

      assert {:more, _partial, conn} = BodyReader.read_body(conn, length: 8_000_000)
      refute Map.has_key?(conn.private, GithubWebhook.raw_body_key())
    end

    test "leaves the stock body reader in place for every other path" do
      conn = conn(:post, "/api/v1/state", @payload)

      assert {:ok, @payload, conn} = BodyReader.read_body(conn, length: 8_000_000)
      refute Map.has_key?(conn.private, GithubWebhook.raw_body_key())
    end
  end

  describe "wiring" do
    test "the router mounts the receiver at the path the body reader watches" do
      routes = AiurWeb.Router.__routes__()

      route = Enum.find(routes, &(&1.plug == AiurWeb.GithubWebhookController))

      assert route.path == GithubWebhook.path()
      assert route.verb == :post
      # Phoenix would otherwise log the whole decoded payload on dispatch.
      assert route.metadata.log == false
    end

    test "the receiver route precedes the dashboard catch-all" do
      routes = AiurWeb.Router.__routes__()

      receiver_index = Enum.find_index(routes, &(&1.plug == AiurWeb.GithubWebhookController))
      catch_all_index = Enum.find_index(routes, &(&1.path == "/*path"))

      assert is_integer(catch_all_index)
      assert receiver_index < catch_all_index
    end
  end

  describe "delivery admission" do
    setup do
      dir = Aiur.TestSupport.tmp_root!("aiur-webhook-receiver")

      log =
        start_supervised!({DeliveryLog, name: :"receiver_delivery_log_#{System.unique_integer([:positive])}", state_dir: dir})

      original = Application.get_env(:aiur, :webhook_delivery_log)
      Application.put_env(:aiur, :webhook_delivery_log, log)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:aiur, :webhook_delivery_log)
        else
          Application.put_env(:aiur, :webhook_delivery_log, original)
        end

        File.rm_rf!(dir)
      end)

      %{log: log}
    end

    test "a retried delivery reaches the receiver twice and is admitted once" do
      body = issue_payload(labels: ["bug"], updated_at: "2026-08-10T12:00:00Z")

      assert {:process, admission} = admit(body, delivery: "11111111-2222-3333-4444-555555555555")
      assert admission.event == "issues"

      assert {:drop, :duplicate_delivery, meta} = admit(body, delivery: "11111111-2222-3333-4444-555555555555")
      assert meta.delivery_id == "11111111-2222-3333-4444-555555555555"
    end

    test "two different delivery ids carrying the same event are admitted once" do
      body = issue_payload(labels: ["bug"], updated_at: "2026-08-10T12:00:00Z")

      assert {:process, _admission} = admit(body, delivery: "aaaaaaaa-0000-0000-0000-000000000001")
      assert {:drop, :duplicate_event, meta} = admit(body, delivery: "bbbbbbbb-0000-0000-0000-000000000002")
      assert is_binary(meta.semantic_key)
    end

    test "an out-of-order labeled pair converges on the newer label list" do
      newer = issue_payload(labels: ["bug", "priority:1"], updated_at: "2026-08-10T12:00:05Z")
      older = issue_payload(labels: ["bug"], updated_at: "2026-08-10T12:00:00Z")

      assert {:process, admission} = admit(newer, delivery: "cccccccc-0000-0000-0000-000000000001")
      assert admission.label_state.labels == ["bug", "priority:1"]
      refute admission.label_state.refresh_required?

      assert {:drop, :stale_state, _meta} = admit(older, delivery: "dddddddd-0000-0000-0000-000000000002")
    end

    test "every admission outcome still acknowledges with 202" do
      body = issue_payload(labels: ["bug"], updated_at: "2026-08-10T12:00:00Z")

      first = signed_delivery(body, "eeeeeeee-0000-0000-0000-000000000001")
      duplicate = signed_delivery(body, "eeeeeeee-0000-0000-0000-000000000001")

      assert first.status == 202
      assert duplicate.status == 202
      assert Jason.decode!(duplicate.resp_body) == %{"status" => "accepted"}
    end

    test "a wedged store cannot hold the response past GitHub's retry deadline" do
      # A store that never answers. Without the admission deadline the receiver
      # would block on its 30s call timeout, GitHub would abandon the delivery at
      # 10s, and the retry would arrive with the original still in flight.
      wedged = start_supervised!({Task, fn -> Process.sleep(:infinity) end}, id: :wedged_store)
      Application.put_env(:aiur, :webhook_delivery_log, wedged)
      Application.put_env(:aiur, :webhook_admission_timeout_ms, 50)
      on_exit(fn -> Application.delete_env(:aiur, :webhook_admission_timeout_ms) end)

      body = issue_payload(labels: ["bug"], updated_at: "2026-08-10T12:00:00Z")

      {microseconds, conn} =
        :timer.tc(fn -> signed_delivery(body, "99999999-0000-0000-0000-000000000001") end)

      assert conn.status == 202
      assert microseconds < 5_000_000, "receiver took #{div(microseconds, 1000)}ms against a wedged store"

      # Fails open: an unverifiable delivery is admitted rather than lost.
      assert {:process, admission} = Map.fetch!(conn.private, GithubWebhook.admission_key())
      assert admission.delivery_id == "99999999-0000-0000-0000-000000000001"
    end

    test "a delivery that fails signature verification never reaches the store", %{log: log} do
      body = issue_payload(labels: ["bug"], updated_at: "2026-08-10T12:00:00Z")

      unsigned =
        body
        |> build_conn(signature: github_signature("wrong-secret", body))
        |> put_req_header("x-github-delivery", "ffffffff-0000-0000-0000-000000000001")
        |> put_req_header("x-github-event", "issues")
        |> call()

      assert unsigned.status == 401
      assert DeliveryLog.size(log) == 0

      # The same id is still claimable, proving the rejected request left no trace.
      assert {:process, _admission} = admit(body, delivery: "ffffffff-0000-0000-0000-000000000001")
    end
  end

  describe "AiurWeb.GithubWebhook.Signature" do
    test "compares digests with a constant-time function" do
      # Asserted structurally as well as behaviourally: a naive `==` passes
      # every behavioural test above while leaking the signature by timing.
      # Read the object code rather than `:code.which/1`, which returns
      # `:cover_compiled` under the coverage partition CI runs.
      {_module, beam, _path} = :code.get_object_code(Signature)
      {:ok, {_module, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])

      assert {Plug.Crypto, :secure_compare, 2} in imports
    end

    test "fails closed on absent and duplicated headers" do
      assert Signature.verify(@payload, [], @secret) == {:error, :missing_signature}

      signature = github_signature(@secret, @payload)
      assert Signature.verify(@payload, [signature, signature], @secret) == {:error, :malformed_signature}
    end

    test "distinguishes a mismatching digest from a malformed one" do
      assert Signature.verify(@payload, [github_signature("other", @payload)], @secret) == {:error, :signature_mismatch}
      assert Signature.verify(@payload, ["sha256=zz"], @secret) == {:error, :malformed_signature}
    end

    test "verifies against the exact bytes, not the parsed document" do
      signature = github_signature(@secret, @payload)

      assert Signature.verify(@payload, [signature], @secret) == :ok
      assert Signature.verify(@payload <> " ", [signature], @secret) == {:error, :signature_mismatch}
    end
  end

  # GitHub's documented algorithm, written out here rather than delegated to the
end
