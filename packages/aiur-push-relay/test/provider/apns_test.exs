defmodule AiurPushRelay.Provider.ApnsTest do
  use ExUnit.Case, async: true
  alias AiurPushRelay.Provider.Apns
  alias AiurPushRelay.Provider.Apns.Jwt
  alias AiurPushRelay.ApnsFake, as: Fake
  Code.require_file("../support/apns_fake.ex", __DIR__)

  setup do
    key = JOSE.JWK.generate_key({:ec, "P-256"})
    clock = start_supervised!({Agent, fn -> 10_000 end})

    jwt =
      start_supervised!(
        {Jwt,
         config: %{key: key, team: "team", kid: "key"}, clock: fn -> Agent.get(clock, & &1) end}
      )

    pin = %{"title" => "Aiur", "body" => "Open Aiur"}
    row = %{app_topic: "org.aiur", push_token: "device/token", environment: "sandbox"}

    envelope = %{
      "sealed" => "opaque",
      "kid" => "seal-key",
      "ttl_s" => 60,
      "push_class" => "alert_normal",
      "collapse_token" => "collapse",
      "fallback" => %{"title" => "injected", "body" => "private"}
    }

    %{jwt: jwt, key: key, clock: clock, pin: pin, row: row, envelope: envelope}
  end

  defp deliver(ctx, responses, extra \\ []) do
    {:ok, fake} = Fake.start(responses)
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)

    opts = [
      jwt: ctx.jwt,
      pins: %{"org.aiur" => ctx.pin},
      now: 10_000,
      transport: Fake.transport(fake)
    ]

    {Apns.deliver(ctx.row, ctx.envelope, Keyword.merge(opts, extra)), Fake.requests(fake)}
  end

  test "builds pinned alert, sealed fields, headers and sandbox URL", ctx do
    assert {:ok, [request]} = deliver(ctx, [Fake.response(200)])

    assert Jason.decode!(request.body) == %{
             "aps" => %{"alert" => ctx.pin, "mutable-content" => 1},
             "s" => "opaque",
             "k" => "seal-key",
             "v" => 1
           }

    assert request.method == "POST"
    assert request.host == "api.sandbox.push.apple.com"
    assert request.path == "/3/device/device%2Ftoken"
    assert request.scheme == :https
    headers = Map.new(request.headers)
    assert headers["apns-topic"] == "org.aiur"
    assert headers["apns-push-type"] == "alert"
    assert headers["apns-priority"] == "5"
    assert headers["apns-expiration"] == "10060"
    assert headers["apns-collapse-id"] == "collapse"
    assert "bearer " <> token = headers["authorization"]
    assert {true, claims, jws} = JOSE.JWT.verify_strict(ctx.key, ["ES256"], token)
    assert claims.fields == %{"iss" => "team", "iat" => 10_000}
    assert jws.fields["kid"] == "key"
  end

  test "production high priority zero TTL omits absent collapse ID", ctx do
    ctx = %{
      ctx
      | row: %{ctx.row | environment: "production"},
        envelope:
          Map.merge(ctx.envelope, %{
            "push_class" => "alert_high",
            "ttl_s" => 0,
            "collapse_token" => nil
          })
    }

    assert {:ok, [request]} = deliver(ctx, [Fake.response(200)])
    assert request.host == "api.push.apple.com"
    headers = Map.new(request.headers)
    assert headers["apns-priority"] == "10"
    assert headers["apns-expiration"] == "0"
    refute Map.has_key?(headers, "apns-collapse-id")
  end

  test "oversized JSON and unknown topic never call transport", ctx do
    large = %{ctx | envelope: Map.put(ctx.envelope, "sealed", String.duplicate("\\", 3000))}
    assert {{:error, :payload_too_large}, []} = deliver(large, [])
    assert {{:error, :unknown_topic}, []} = deliver(ctx, [], pins: %{})
  end

  test "maps recorded response and transport failures", ctx do
    for {response, expected} <- [
          {Fake.response(410, "Unregistered"), {:gone, "Unregistered"}},
          {Fake.response(400, "BadDeviceToken"), {:gone, "BadDeviceToken"}},
          {Fake.response(429, "TooManyRequests"), {:retry, 60_000}},
          {Fake.response(500, "InternalServerError"), {:retry, 5_000}},
          {Fake.response(503, "ServiceUnavailable"), {:retry, 5_000}},
          {{:error, :closed}, {:retry, 5_000}},
          {Fake.response(400, "BadTopic"), {:error, "BadTopic"}},
          {Fake.response(403, "InvalidProviderToken"), {:error, "InvalidProviderToken"}},
          {Fake.response(404, "private-secret"), {:error, "Unknown"}},
          {{:ok, %{status: 400, body: "not-json"}}, {:error, "Unknown"}}
        ] do
      assert {^expected, [_]} = deliver(ctx, [response])
    end
  end

  test "expired provider token refreshes once and bounds repeated expiry", ctx do
    assert {:ok, [first, second]} =
             deliver(ctx, [Fake.response(403, "ExpiredProviderToken"), Fake.response(200)])

    refute first.headers == second.headers

    assert {{:retry, 5_000}, [_, _]} =
             deliver(ctx, List.duplicate(Fake.response(403, "ExpiredProviderToken"), 2))
  end

  test "JWT cache refreshes at forty minutes and reuses a concurrent refresh", ctx do
    first = Jwt.token(ctx.jwt)
    assert Jwt.token(ctx.jwt) == first
    Agent.update(ctx.clock, fn _ -> 12_399 end)
    assert Jwt.token(ctx.jwt) == first
    Agent.update(ctx.clock, fn _ -> 12_400 end)
    second = Jwt.token(ctx.jwt)
    refute second == first
    assert JOSE.JWT.peek_payload(second).fields["iat"] == 12_400
    third = Jwt.token(ctx.jwt, second)
    refute third == second
    assert Jwt.token(ctx.jwt, second) == third
  end

  test "JWT status redacts signing material without assuming a current message", ctx do
    token = Jwt.token(ctx.jwt)
    status = inspect(:sys.get_status(ctx.jwt), limit: :infinity)
    assert status =~ "redacted"
    refute status =~ token
    refute status =~ "format_status/1 crashed"

    assert Jwt.format_status(%{state: %{token: token}, message: {:token, token}}) ==
             %{state: :redacted, message: :redacted}
  end
end
