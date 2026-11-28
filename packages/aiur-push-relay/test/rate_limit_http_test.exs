defmodule AiurPushRelay.RateLimitHttpTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  alias AiurPushRelay.Router
  alias AiurPushRelay.Store.SQLite

  setup do
    path = Path.join(System.tmp_dir!(), "relay-limit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    store_pid = start_supervised!({SQLite, path: Path.join(path, "db")})
    tasks = start_supervised!(Task.Supervisor)
    store = {SQLite, store_pid}

    sender =
      start_supervised!(
        {AiurPushRelay.Send, store: store, tasks: tasks, provider: AiurPushRelay.Provider.Fake}
      )

    topic = "test.#{System.unique_integer([:positive])}"
    old_owner = Application.get_env(:aiur_push_relay, :fake_owner)
    Application.put_env(:aiur_push_relay, :fake_owner, self())
    on_exit(fn -> Application.put_env(:aiur_push_relay, :fake_owner, old_owner) end)
    pin = %{"title" => "Aiur", "body" => "Open Aiur"}
    opts = Router.init(store: store, sender: sender, pins: %{topic => pin})
    %{opts: opts, store: store, topic: topic, pin: pin}
  end

  test "send burst is limited and an accepted idempotency replay is free", ctx do
    credentials = credentials(ctx)

    for number <- 1..10 do
      body = envelope(ctx, credentials) |> Map.put("idempotency_key", "burst-#{number}")
      assert request(ctx, :post, "/v1/send", body, credentials["send_secret"]).status == 202
    end

    pids =
      for _ <- 1..10 do
        assert_receive {:delivery, pid, _, _}, 2_000
        pid
      end

    Enum.each(pids, &send(&1, {:result, :ok}))
    replay = envelope(ctx, credentials) |> Map.put("idempotency_key", "burst-1")
    assert request(ctx, :post, "/v1/send", replay, credentials["send_secret"]).status == 202

    limited = envelope(ctx, credentials) |> Map.put("idempotency_key", "burst-11")
    response = request(ctx, :post, "/v1/send", limited, credentials["send_secret"])
    assert response.status == 429
    assert Jason.decode!(response.resp_body) == %{"error" => "rate_limited", "retry_after_s" => 60}
    assert get_resp_header(response, "retry-after") == ["60"]
  end

  test "handle creation is limited per source IP", ctx do
    for _ <- 1..20, do: assert(register(ctx).status == 201)
    response = register(ctx)
    assert response.status == 429
    assert Jason.decode!(response.resp_body)["error"] == "rate_limited"
  end

  defp request(ctx, method, path, body, secret) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> secret)
    |> Router.call(ctx.opts)
  end

  defp register(ctx) do
    request(
      ctx,
      :post,
      "/v1/handles",
      %{
        "platform" => "apns",
        "push_token" => "private-token",
        "app_topic" => ctx.topic,
        "environment" => "sandbox"
      },
      ""
    )
  end

  defp credentials(ctx), do: Jason.decode!(register(ctx).resp_body)

  defp envelope(ctx, credentials) do
    %{
      "v" => 1,
      "handle" => credentials["handle"],
      "push_class" => "alert_normal",
      "ttl_s" => 60,
      "sealed" => "opaque-sealed",
      "kid" => "kid",
      "idempotency_key" => "key",
      "fallback" => ctx.pin
    }
  end
end
