defmodule AiurPushRelay.RelayTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog
  alias AiurPushRelay.{Router, Store}
  alias AiurPushRelay.Store.SQLite

  setup do
    path = Path.join(System.tmp_dir!(), "relay-#{System.unique_integer([:positive])}")
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
    %{opts: opts, store: store, topic: topic, pin: pin, db: Path.join(path, "db")}
  end

  defp request(ctx, method, path, body \\ %{}, secret \\ "") do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> secret)
    |> Router.call(ctx.opts)
  end

  defp register(ctx, extra \\ %{}) do
    request(
      ctx,
      :post,
      "/v1/handles",
      Map.merge(
        %{
          "platform" => "apns",
          "push_token" => "private-token",
          "app_topic" => ctx.topic,
          "environment" => "sandbox"
        },
        extra
      )
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

  test "create returns handle and secret, stores only the hash", ctx do
    response = register(ctx)
    assert response.status == 201
    c = Jason.decode!(response.resp_body)
    assert c["handle"] =~ ~r/^h_[A-Z2-7]{26}$/
    assert {:ok, bytes} = Base.url_decode64(c["send_secret"], padding: false)
    assert byte_size(bytes) == 32
    assert {:ok, row} = Store.call(ctx.store, :get, [c["handle"]])
    assert row.send_secret_sha256 == :crypto.hash(:sha256, c["send_secret"])
    refute Map.has_key?(row, :send_secret)
    refute File.read!(ctx.db <> "-wal") =~ c["send_secret"]
    assert register(ctx).status == 201
  end

  test "unknown app_topic and malformed registration are rejected", ctx do
    assert register(ctx, %{"app_topic" => "other.app"}).status == 422
    assert register(ctx, %{"platform" => "other"}).status == 422
    assert request(ctx, :post, "/v1/handles", []).status == 422
  end

  test "wrong secret is 401 and nothing is delivered", ctx do
    c = credentials(ctx)
    assert request(ctx, :post, "/v1/send", envelope(ctx, c), "wrong").status == 401
    refute_receive {:delivery, _, _, _}
  end

  test "same idempotency_key concurrently sends once and returns before provider finishes", ctx do
    c = credentials(ctx)

    responses =
      1..8
      |> Task.async_stream(
        fn _ -> request(ctx, :post, "/v1/send", envelope(ctx, c), c["send_secret"]).status end,
        max_concurrency: 4
      )
      |> Enum.to_list()

    assert responses == List.duplicate({:ok, 202}, 8)
    assert_receive {:delivery, pid, _, _}
    refute_receive {:delivery, _, _, _}
    send(pid, {:result, :ok})
  end

  test "gone handle answers 410 and authenticated deletion removes it", ctx do
    c = credentials(ctx)
    assert request(ctx, :post, "/v1/send", envelope(ctx, c), c["send_secret"]).status == 202
    assert_receive {:delivery, pid, _, _}
    send(pid, {:result, {:gone, :invalid_token}})
    # A monitor gives a deterministic barrier after finish has persisted the provider result.
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert request(ctx, :post, "/v1/send", envelope(ctx, c), c["send_secret"]).status == 410
    assert request(ctx, :delete, "/v1/handles/#{c["handle"]}", %{}, "wrong").status == 401
    assert request(ctx, :delete, "/v1/handles/#{c["handle"]}", %{}, c["send_secret"]).status == 204
    assert request(ctx, :delete, "/v1/handles/#{c["handle"]}", %{}, c["send_secret"]).status == 404
  end

  test "fallback mismatch is rejected; provider receives exactly the configured pin", ctx do
    c = credentials(ctx)
    e = envelope(ctx, c)

    response =
      request(
        ctx,
        :post,
        "/v1/send",
        Map.put(e, "fallback", %{"title" => "injected", "body" => "text"}),
        c["send_secret"]
      )

    assert response.status == 422
    assert Jason.decode!(response.resp_body)["error"] == "fallback_mismatch"
    refute_receive {:delivery, _, _, _}

    assert request(ctx, :post, "/v1/send", Map.put(e, "unexpected", "discard"), c["send_secret"]).status ==
             202

    assert_receive {:delivery, pid, _, delivered}
    assert delivered["fallback"] == ctx.pin
    refute Map.has_key?(delivered, "unexpected")
    send(pid, {:result, :ok})
  end

  test "body and sealed size limits and schema fail before delivery", ctx do
    c = credentials(ctx)
    e = envelope(ctx, c)

    assert request(
             ctx,
             :post,
             "/v1/send",
             Map.put(e, "sealed", String.duplicate("a", 3401)),
             c["send_secret"]
           ).status == 413

    assert request(ctx, :post, "/v1/send", Map.put(e, "ttl_s", -1), c["send_secret"]).status == 422

    assert request(
             ctx,
             :post,
             "/v1/send",
             Map.put(e, "padding", String.duplicate("a", 8193)),
             c["send_secret"]
           ).status == 413

    assert conn(:post, "/v1/send", "{") |> Router.call(ctx.opts) |> Map.fetch!(:status) == 422

    assert request(ctx, :post, "/v1/send", Map.put(e, "handle", %{}), c["send_secret"]).status ==
             422

    assert request(ctx, :post, "/v1/send", Map.delete(e, "handle"), c["send_secret"]).status == 422
    refute_receive {:delivery, _, _, _}
  end

  test "sealed, token, and secret never reach logger even on provider exception", ctx do
    c = credentials(ctx)

    log =
      capture_log(fn ->
        assert request(ctx, :post, "/v1/send", envelope(ctx, c), c["send_secret"]).status == 202
        assert_receive {:delivery, pid, _, _}
        ref = Process.monitor(pid)
        send(pid, {:result, :raise})
        assert_receive {:DOWN, ^ref, :process, ^pid, _}
      end)

    assert log =~ "relay_delivery"
    refute log =~ "opaque-sealed"
    refute log =~ "private-token"
    refute log =~ c["send_secret"]
  end

  test "Bandit serves the HTTP health endpoint over a real socket", ctx do
    pid =
      start_supervised!(
        {Bandit, plug: {Router, Map.to_list(ctx.opts)}, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    :ok =
      :gen_tcp.send(socket, "GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

    response = read_socket(socket, "")
    :gen_tcp.close(socket)
    assert response =~ "HTTP/1.1 200"
    assert response =~ ~s({"store":"ok"})
  end

  defp read_socket(socket, result) do
    case :gen_tcp.recv(socket, 0, 2000) do
      {:ok, bytes} -> read_socket(socket, result <> bytes)
      {:error, :closed} -> result
    end
  end

  test "queue admission failure releases the key for a later retry", ctx do
    c = credentials(ctx)
    e = envelope(ctx, c)
    stop_supervised!(Task.Supervisor)
    assert request(ctx, :post, "/v1/send", e, c["send_secret"]).status == 503
    refute_receive {:delivery, _, _, _}
    tasks = start_supervised!(Task.Supervisor)
    stop_supervised!(AiurPushRelay.Send)

    sender =
      start_supervised!(
        {AiurPushRelay.Send, store: ctx.store, tasks: tasks, provider: AiurPushRelay.Provider.Fake}
      )

    ctx = %{ctx | opts: Map.put(ctx.opts, :sender, sender)}
    assert request(ctx, :post, "/v1/send", e, c["send_secret"]).status == 202
    assert_receive {:delivery, pid, _, _}
    send(pid, {:result, :ok})
  end

  test "locked database fails closed and health reports error", ctx do
    {:ok, db} = Exqlite.Sqlite3.open(ctx.db)
    :ok = Exqlite.Sqlite3.execute(db, "BEGIN IMMEDIATE")

    try do
      assert register(ctx).status == 503
      response = request(ctx, :get, "/healthz")
      assert response.status == 503
      assert Jason.decode!(response.resp_body) == %{"store" => "error"}
    after
      Exqlite.Sqlite3.execute(db, "ROLLBACK")
      Exqlite.Sqlite3.close(db)
    end

    assert request(ctx, :get, "/healthz").status == 200
  end
end
