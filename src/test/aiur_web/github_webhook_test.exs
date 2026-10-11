defmodule AiurWeb.GithubWebhookTest do
  @moduledoc """
  End-to-end coverage for the GitHub webhook receiver.

  Every HTTP test drives `AiurWeb.Endpoint.call/2` rather than the router
  directly: the raw-body capture that HMAC verification depends on lives in the
  endpoint's `Plug.Parsers` configuration, so a router-only test would verify
  against bytes the production stack never produces.
  """

  use Aiur.TestSupport.GithubWebhookReceiverCase

  alias AiurWeb.GithubWebhook

  @secret_env "AIUR_GITHUB_WEBHOOK_SECRET"
  @secret "s3cr3t-webhook-token"
  @payload ~s({"action":"submitted","number":1676})

  # Allowed-contributor intake (#2957): a forged or unsigned `issues.opened`
  # naming an allowed author must never reach the delivery tail — the only
  # path into intake — so it can neither wake the Executor nor be audited as
  # an accept.
  describe "allowed-contributor intake behind the signature boundary" do
    setup do
      test = self()
      original = Application.get_env(:aiur, :github_webhook_deliver_fun)
      Application.put_env(:aiur, :github_webhook_deliver_fun, fn event, payload -> send(test, {:delivered, event, payload}) && :ok end)

      on_exit(fn ->
        if is_nil(original),
          do: Application.delete_env(:aiur, :github_webhook_deliver_fun),
          else: Application.put_env(:aiur, :github_webhook_deliver_fun, original)
      end)
    end

    @opened ~s({"action":"opened","repository":{"full_name":"acme/app"},"issue":{"number":5,"user":{"id":42,"login":"alice","type":"User"}}})

    defp issues_delivery(body, signature) do
      body
      |> build_conn(signature: signature)
      |> put_req_header("x-github-event", "issues")
      |> put_req_header("x-github-delivery", "ac-#{System.unique_integer([:positive])}")
      |> call()
    end

    test "an unsigned issues.opened is rejected and never delivered" do
      assert issues_delivery(@opened, nil).status == 401
      refute_received {:delivered, _, _}
    end

    test "a forged signature on issues.opened is rejected and never delivered" do
      assert issues_delivery(@opened, github_signature("attacker-guess", @opened)).status == 401
      refute_received {:delivered, _, _}
    end

    test "a correctly signed issues.opened is delivered (positive control)" do
      assert issues_delivery(@opened, github_signature(@secret, @opened)).status == 202
      assert_received {:delivered, "issues", %{"action" => "opened"}}
    end
  end

  describe "POST #{GithubWebhook.path()}" do
    test "accepts a delivery carrying a valid signature" do
      conn = deliver(@payload, signature: github_signature(@secret, @payload))

      assert conn.status == 202
      assert Jason.decode!(conn.resp_body) == %{"status" => "accepted"}
    end

    test "rejects a delivery whose signature does not match the body" do
      conn = deliver(@payload, signature: github_signature("wrong-secret", @payload))

      assert conn.status == 401
      assert %{"error" => %{"code" => "invalid_signature"}} = Jason.decode!(conn.resp_body)
      assert conn.halted
    end

    test "rejects a delivery with no signature header" do
      conn = deliver(@payload, signature: nil)

      assert conn.status == 401
    end

    test "rejects a body that is byte-for-byte different from what was signed" do
      signed = ~s({"action":"submitted","number":1676})
      # Same JSON document, different bytes. Verifying a re-encoded parsed map
      # instead of the raw bytes would wrongly accept this.
      delivered = ~s({"action": "submitted", "number": 1676})

      assert Jason.decode!(signed) == Jason.decode!(delivered)

      conn = deliver(delivered, signature: github_signature(@secret, signed))

      assert conn.status == 401
    end

    test "ignores the legacy SHA-1 signature header" do
      sha1 = "sha1=" <> Base.encode16(:crypto.mac(:hmac, :sha, @secret, @payload), case: :lower)

      conn =
        @payload
        |> build_conn(signature: nil)
        |> put_req_header("x-hub-signature", sha1)
        |> call()

      assert conn.status == 401
    end

    test "rejects malformed signature headers" do
      for header <- [
            "sha256=not-hex-at-all-not-hex-at-all-not-hex-at-all-not-hex-at-all!!",
            "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, @secret, @payload), case: :lower) <> "ff",
            Base.encode16(:crypto.mac(:hmac, :sha256, @secret, @payload), case: :lower),
            "sha256=",
            "  "
          ] do
        assert deliver(@payload, signature: header).status == 401, "expected #{inspect(header)} to be rejected"
      end
    end

    test "accepts an uppercase hex digest, which GitHub's spec permits" do
      upper = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, @secret, @payload), case: :upper)

      assert deliver(@payload, signature: upper).status == 202
    end

    test "keys the HMAC off the configured secret verbatim" do
      # Trimming the secret would silently verify against different key bytes
      # than the operator configured on GitHub's side.
      padded = " #{@secret} "
      System.put_env(@secret_env, padded)

      assert deliver(@payload, signature: github_signature(padded, @payload)).status == 202
      assert deliver(@payload, signature: github_signature(@secret, @payload)).status == 401
    end

    test "rejects a correctly signed body whose content type was never parsed" do
      # `pass: ["*/*"]` lets unparsed content types through, so no raw bytes are
      # captured. Without provable bytes the receiver must fail closed.
      conn =
        :post
        |> conn(GithubWebhook.path(), @payload)
        |> put_req_header("content-type", "text/plain")
        |> put_req_header("x-hub-signature-256", github_signature(@secret, @payload))
        |> call()

      assert conn.status == 401
    end
  end

  describe "no secret configured" do
    setup do
      System.delete_env(@secret_env)
      test_pid = self()
      Application.put_env(:aiur, :github_webhook_alert_fun, fn name, opts -> send(test_pid, {:alert, name, opts}) && :ok end)
      :ok
    end

    test "rejects a delivery that carries an otherwise valid signature" do
      conn = deliver(@payload, signature: github_signature(@secret, @payload))

      assert conn.status == 401
      assert_receive {:alert, "system.github_webhook.secret_missing", opts}, 1000
      assert Keyword.fetch!(opts, :needs_attention) == true
    end

    test "rejects an unsigned delivery and raises a needs-attention alert" do
      assert deliver(@payload, signature: nil).status == 401

      assert_receive {:alert, "system.github_webhook.secret_missing", opts}, 1000
      assert Keyword.fetch!(opts, :needs_attention) == true
      assert Keyword.fetch!(opts, :reason) =~ @secret_env
    end

    test "rejects a delivery when the secret is set but blank" do
      System.put_env(@secret_env, "   ")

      assert deliver(@payload, signature: github_signature(@secret, @payload)).status == 401
      assert_receive {:alert, "system.github_webhook.secret_missing", _opts}, 1000
    end

    test "throttles the alert so a redelivery storm cannot become an alert storm" do
      for _attempt <- 1..3, do: assert(deliver(@payload, signature: nil).status == 401)

      assert_receive {:alert, "system.github_webhook.secret_missing", _opts}, 1000
      refute_receive {:alert, _name, _opts}, 50
    end
  end
end
