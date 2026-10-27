defmodule AiurWeb.EventsChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest
  alias Aiur.Application.ExportChildren
  alias Aiur.TestSupport.{EndpointStubs, RuntimeChildren}
  alias Aiur.Events.Export
  alias Aiur.Events.Export.Exporter
  alias AiurWeb.{Endpoint, EventsAuth, EventsSocket, FinancialDataAccess, StreamdeckAuth}
  @endpoint Endpoint

  setup do
    RuntimeChildren.ensure_financial_data_running()
    root = Path.join(System.tmp_dir!(), "events-channel-#{System.unique_integer([:positive])}")
    previous_root = Application.get_env(:aiur, :runtime_state_dir)
    previous_status = :persistent_term.get({Export, :status}, :missing)
    previous_config = Application.get_env(:aiur, Endpoint, [])
    config = previous_config |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64)) |> EndpointStubs.scope()
    Application.put_env(:aiur, Endpoint, config)
    Application.put_env(:aiur, :runtime_state_dir, root)
    Aiur.TestSupport.start_owned_endpoint!()
    Endpoint.config_change([{Endpoint, config}], [])

    on_exit(fn ->
      Application.put_env(:aiur, Endpoint, previous_config)
      Application.put_env(:aiur, :runtime_state_dir, previous_root)
      if previous_status == :missing, do: :persistent_term.erase({Export, :status}), else: :persistent_term.put({Export, :status}, previous_status)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    [{Exporter, callbacks}] = ExportChildren.child_specs(true)
    opts = Keyword.merge(callbacks, name: nil, identity: fn -> {:ok, "test/instance"} end, subscribe: fn _ -> :ok end)
    pid = start_supervised!({Exporter, opts})
    :sys.get_state(pid)
    append(pid, 4)
    assert Export.status().head_seq == 5
    {:ok, exporter: pid, root: root}
  end

  test "only a valid events token connects" do
    assert :error = EventsSocket.connect(%{}, socket(EventsSocket), %{})
    assert :error = EventsSocket.connect(%{"token" => "garbage"}, socket(EventsSocket), %{})
    {:ok, other} = StreamdeckAuth.issue_token()
    assert :error = EventsSocket.connect(%{"token" => other}, socket(EventsSocket), %{})
    {:ok, token} = EventsAuth.issue_token()
    assert {:ok, _} = EventsSocket.connect(%{"token" => token}, socket(EventsSocket), %{})
    assert {:error, %{reason: "unauthorized"}} = join(socket(EventsSocket), "events:feed")
  end

  test "join replays records after cursor then live without duplicates", %{exporter: pid} do
    socket = joined(%{"after" => 3})
    assert_push("record", %{"seq" => 4})
    assert_push("record", %{"seq" => 5})
    append(pid, 1)
    assert_push("record", %{"seq" => 6})
    send(socket.channel_pid, {:export_appended, 6, Export.status().epoch})
    send(socket.channel_pid, :heartbeat)
    assert_push("heartbeat", %{head_seq: 6})
    refute_push("record", _, 20)
  end

  test "subscribes before first journal read" do
    :erlang.trace_pattern({Phoenix.PubSub, :subscribe, 3}, true, [:local])
    :erlang.trace_pattern({Export, :read, 4}, true, [:local])
    :erlang.trace(:new, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      :erlang.trace(:new, false, [:call])
      :erlang.trace_pattern({Phoenix.PubSub, :subscribe, 3}, false, [:local])
      :erlang.trace_pattern({Export, :read, 4}, false, [:local])
    end)

    socket = joined(%{"after" => 3})
    channel = socket.channel_pid
    assert_receive {:trace, ^channel, :call, first}, 1_000
    assert {Phoenix.PubSub, :subscribe, [Aiur.PubSub, "events:export", _]} = first
    assert_receive {:trace, ^channel, :call, {Export, :read, _}}, 1_000
  end

  test "epoch mismatch gets one reset then resumes live", %{exporter: pid} do
    joined(%{"after" => 3, "epoch" => "old"})
    assert_push("record", %{type: "reset", head_seq: 5, epoch: epoch})
    assert epoch == Export.status().epoch
    append(pid, 1)
    assert_push("record", %{"seq" => 6})
    refute_push("record", %{type: "reset"}, 20)
  end

  test "retention cursor resets without replaying retained records", %{exporter: pid} do
    :persistent_term.put({Export, :status}, %{Export.status() | oldest_seq: 5})
    joined(%{"after" => 3})
    assert_push("record", %{type: "reset", head_seq: 5, oldest_seq: 5})
    append(pid, 1)
    assert_push("record", %{"seq" => 6})
    refute_push("record", _, 20)
  end

  test "channel schedules the 25 second heartbeat without client messages" do
    joined(%{})
    started = System.monotonic_time(:millisecond)
    assert_push("heartbeat", %{head_seq: 5}, 27_000)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 24_000
  end

  test "client publish is rejected" do
    socket = joined(%{})
    ref = push(socket, "publish", %{"topic" => "ticket.42.pr.merged"})
    assert_reply(ref, :error, %{reason: "read_only"})
    assert Export.status().head_seq == 5
  end

  test "heartbeat carries current head and observed time" do
    socket = joined(%{})
    before = DateTime.utc_now()
    send(socket.channel_pid, :heartbeat)
    assert_push("heartbeat", %{head_seq: 5, observed_at: observed})
    assert {:ok, date, 0} = DateTime.from_iso8601(observed)
    assert DateTime.compare(date, before) != :lt
    assert DateTime.diff(DateTime.utc_now(), date) <= 1
  end

  test "channel expires from a real short-lived signed token" do
    Process.flag(:trap_exit, true)
    {:ok, generation, _} = token_identity()
    token = Phoenix.Token.sign(Endpoint, "events-v1", %{generation: generation, expires_at_ms: System.system_time(:millisecond) + 500})
    {:ok, authenticated} = EventsSocket.connect(%{"token" => token}, socket(EventsSocket), %{})
    {:ok, _, socket} = subscribe_and_join(authenticated, "events:feed", %{})
    ref = Process.monitor(socket.channel_pid)
    assert_push("record", %{type: "auth_expiring", in_ms: remaining})
    assert remaining in 0..500
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1_000
  end

  test "credential change closes channel" do
    Process.flag(:trap_exit, true)
    socket = joined(%{})
    ref = Process.monitor(socket.channel_pid)
    previous = System.get_env("AIUR_DASHBOARD_PASSWORD")
    on_exit(fn -> System.put_env("AIUR_DASHBOARD_PASSWORD", previous) end)
    System.put_env("AIUR_DASHBOARD_PASSWORD", "rotated-secret")
    assert {:ok, _} = FinancialDataAccess.current_configuration_generation()
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1_000
  end

  test "credentials rotated between connect and join refuse the old socket" do
    socket = authenticated()
    previous = System.get_env("AIUR_DASHBOARD_PASSWORD")
    on_exit(fn -> System.put_env("AIUR_DASHBOARD_PASSWORD", previous) end)
    System.put_env("AIUR_DASHBOARD_PASSWORD", "rotated-before-join")
    assert {:ok, _} = FinancialDataAccess.current_configuration_generation()
    assert {:error, %{reason: "unauthorized"}} = subscribe_and_join(socket, "events:feed", %{})
  end

  test "disabled export refuses join and issuance" do
    :persistent_term.erase({Export, :status})
    assert {:error, %{reason: "feature_disabled"}} = subscribe_and_join(authenticated(), "events:feed", %{})
    conn = request_token()
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => %{"code" => "feature_disabled"}}
  end

  test "token endpoint requires dashboard auth and returns a usable token" do
    conn = request_token()
    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    assert %{"token" => token, "expires_in_seconds" => 300} = Jason.decode!(conn.resp_body)
    assert {:ok, _, _} = EventsAuth.verify_token(token)
    assert request_token("wrong").status == 401
  end

  test "slow client resets after 2001 unread sequence positions", %{exporter: pid} do
    socket = joined(%{})
    send(socket.channel_pid, :heartbeat)
    assert_push("heartbeat", %{head_seq: 5})
    :sys.suspend(socket.channel_pid)
    append(pid, 2_001)
    :sys.resume(socket.channel_pid)
    assert_push("record", %{type: "reset", head_seq: 2_006}, 3_000)
    send(socket.channel_pid, :heartbeat)
    assert_push("heartbeat", %{head_seq: 2_006}, 3_000)
    refute_push("record", _, 20)
  end

  test "pages beyond 500 and honors topic filters", %{exporter: pid} do
    append(pid, 3, "ticket.43.pr.merged")
    append(pid, 510)
    joined(%{"after" => 3, "topics" => ["ticket.42.pr.merged"]})
    for seq <- [4, 5] ++ Enum.to_list(9..518), do: assert_push("record", %{"seq" => ^seq}, 3_000)
    refute_push("record", _, 20)
    append(pid, 1)
    assert_push("record", %{"seq" => 519})
  end

  test "rejects invalid cursors and private filters" do
    for payload <- [%{"after" => -1}, %{"after" => "3"}, %{"epoch" => 7}] do
      assert {:error, %{reason: "invalid_cursor"}} = subscribe_and_join(authenticated(), "events:feed", payload)
    end

    for topics <- [["#"], ["private.topic"], [2], "ticket.*.pr.merged"] do
      assert {:error, %{reason: "topic_not_exported"}} = subscribe_and_join(authenticated(), "events:feed", %{"topics" => topics})
    end
  end

  test "unavailable and disabled connections report error and stop", %{root: root, exporter: exporter} do
    Process.flag(:trap_exit, true)
    status = Export.status()
    socket = joined(%{})
    ref = Process.monitor(socket.channel_pid)
    :persistent_term.erase({Export, :status})
    send(socket.channel_pid, :heartbeat)
    assert_push("record", %{type: "error", code: "feature_disabled"})
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1_000
    # Restore a readable status and then corrupt the journal to exercise the reader error.
    :persistent_term.put({Export, :status}, status)
    joined(%{"after" => 3})
    assert_push("record", %{"seq" => 4})
    assert_push("record", %{"seq" => 5})
    File.write!(Path.join(root, "events/export/seg.1.ndjson"), "broken\n")
    append(exporter, 1)
    assert_push("record", %{type: "error", code: "events_unavailable"}, 1_000)
  end

  defp append(pid, count, topic \\ "ticket.42.pr.merged") do
    for _ <- 1..count, do: send(pid, {:event, %{id: System.unique_integer([:positive]), topic: topic}})
    :sys.get_state(pid, 60_000)
  end

  defp token_identity do
    {:ok, token} = EventsAuth.issue_token()
    EventsAuth.verify_token(token)
  end

  defp authenticated do
    {:ok, token} = EventsAuth.issue_token()
    {:ok, authenticated} = EventsSocket.connect(%{"token" => token}, socket(EventsSocket), %{})
    authenticated
  end

  defp joined(payload) do
    {:ok, _, socket} = subscribe_and_join(authenticated(), "events:feed", payload)
    socket
  end

  defp request_token(password \\ "test-dashboard-secret") do
    Plug.Test.conn(:post, "/api/v1/events/token")
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:#{password}"))
    |> AiurWeb.Router.call(AiurWeb.Router.init([]))
  end
end
