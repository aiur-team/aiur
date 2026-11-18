Code.require_file("../../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.ExecutorThreadControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  import Aiur.Conversation.TestSupport
  alias Aiur.Conversation.{Ingest, TestSupport}
  alias Aiur.Executor.ThreadGrant
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Router

  # OGM core #854 moves the operator's conversation with the Executor into its
  # own app: the app must read and post to that thread with a grant that
  # reaches nothing else, and a message sent while no Executor is attached must
  # wait for the next one instead of being refused.

  @secret String.duplicate("t", 64)
  @supervisor_token String.duplicate("s", 32)
  @session Plug.Session.init(store: :cookie, key: "_executor_thread_test", signing_salt: "test")
  @live {:ok, %{state: "attached", live?: true, provider_session_id: "claude-1", binding_id: "b1"}}

  setup context do
    Aiur.TestSupport.start_owned_endpoint!()
    previous_token = System.get_env("AIUR_SUPERVISOR_TOKEN")
    System.put_env("AIUR_SUPERVISOR_TOKEN", @supervisor_token)
    on_exit(fn -> if previous_token, do: System.put_env("AIUR_SUPERVISOR_TOKEN", previous_token), else: System.delete_env("AIUR_SUPERVISOR_TOKEN") end)

    test_pid = self()

    EndpointStubs.put(
      dashboard_writable: true,
      conversation_executor_session_fun: fn -> %{"state" => "live"} end,
      executor_thread_opts: [
        binding_fun: fn -> Process.get(:binding, @live) end,
        delivery_fun: fn -> true end,
        writable: true,
        listener_send_fun: fn ref, text, opts ->
          send(test_pid, {:listener_send, ref, text, opts})
          {:ok, 41}
        end,
        wake_fun: fn record -> send(test_pid, {:wake, record}) end
      ]
    )

    TestSupport.setup(context)
  end

  test "a host grant reads operator and Executor messages in order", %{ref: ref} do
    Ingest.append(ref, source(), [event(1), %{role: "user", msg_id: "u-2", body: "trailers are 16:9", timestamp: DateTime.utc_now(), payload: %{delivery_id: "41"}}])
    assert :ok = flush(ref)

    conn = request(:get, "/api/v1/executor/thread/messages?after=0", grant())
    assert conn.status == 200

    assert %{"messages" => [executor, operator], "next_after" => 2} = Jason.decode!(conn.resp_body)
    assert %{"role" => "executor", "text" => "message 1", "pos" => 1, "delivery" => nil} = executor
    assert %{"role" => "operator", "text" => "trailers are 16:9", "pos" => 2, "delivery" => "delivered", "request_id" => 41} = operator

    assert %{"messages" => [], "next_after" => 2} = request(:get, "/api/v1/executor/thread/messages?after=2", grant()).resp_body |> Jason.decode!()
  end

  test "a send to a live Executor is queued for its session with the host's request id" do
    conn = request(:post, "/api/v1/executor/thread/messages", grant(), %{text: "ship #645", client_request_id: "host-1"})

    assert conn.status == 202
    assert %{"message" => %{"role" => "operator", "text" => "ship #645", "delivery" => "queued", "request_id" => 41}} = Jason.decode!(conn.resp_body)
    assert_received {:listener_send, %{subject: :executor}, "ship #645", opts}
    assert opts[:client_request_id] == "host-1"
    assert opts[:origin] == :http
    refute_received {:wake, _record}
  end

  test "with no Executor attached the message waits for the next session and records a wake" do
    Process.put(:binding, :none)

    conn = request(:post, "/api/v1/executor/thread/messages", grant(), %{text: "are you there?", client_request_id: "host-2"})

    assert conn.status == 202
    assert %{"message" => %{"delivery" => "queued"}} = Jason.decode!(conn.resp_body)
    assert_received {:listener_send, _ref, "are you there?", _opts}
    assert_received {:wake, %{"topic" => "executor.thread.message", "action" => "operator_message", "request_id" => 41}}
    assert %{"can_send" => true, "executor" => %{"attached" => false}} = request(:get, "/api/v1/executor/thread", grant()).resp_body |> Jason.decode!()
  end

  test "a read-only instance refuses the send instead of queueing it" do
    Process.put(:binding, :none)
    opts = Keyword.put(AiurWeb.EndpointConfig.get(:executor_thread_opts), :writable, false)
    EndpointStubs.put(executor_thread_opts: opts)

    conn = request(:post, "/api/v1/executor/thread/messages", grant(), %{text: "hello", client_request_id: "host-3"})

    assert conn.status == 409
    assert %{"error" => "executor_unavailable", "reason" => "read_only"} = Jason.decode!(conn.resp_body)
    refute_received {:listener_send, _ref, _text, _opts}
  end

  test "the supervisor mints a grant that expires and reaches only the thread" do
    conn =
      :post
      |> conn("/api/v1/executor/thread/grants", %{"subject" => "kevin@ogm", "ttl_s" => 60})
      |> put_req_header("authorization", "Bearer " <> @supervisor_token)
      |> put_private(:executor_thread_secret, @secret)
      |> Router.call(Router.init([]))

    assert conn.status == 201
    assert %{"token" => "et1." <> _ = token, "expires_at" => _} = Jason.decode!(conn.resp_body)
    assert request(:get, "/api/v1/executor/thread", token).status == 200

    for path <- ["/api/v1/conversations/resolve?subject=executor", "/api/v1/commands", "/api/v1/state"] do
      assert request(:get, path, token).status == 401, path
    end

    {:ok, %{token: expired}} = ThreadGrant.mint("kevin@ogm", secret: @secret, expires_in: 60, now: DateTime.add(DateTime.utc_now(), -120))
    expired_conn = request(:get, "/api/v1/executor/thread", expired)
    assert expired_conn.status == 401
    assert Jason.decode!(expired_conn.resp_body)["error"]["code"] == "executor_thread_grant_expired"

    assert request(:get, "/api/v1/executor/thread", "et1.forged.sig").status == 401
  end

  test "a host cannot mint a grant with its own grant" do
    conn =
      :post
      |> conn("/api/v1/executor/thread/grants", %{"subject" => "x"})
      |> put_req_header("authorization", "Bearer " <> grant())
      |> Router.call(Router.init([]))

    assert conn.status == 401
  end

  test "a dashboard-session send needs the request header" do
    body = %{text: "hi", client_request_id: "dash-1"}
    assert request(:post, "/api/v1/executor/thread/messages", :basic, body).status == 403
    assert request(:post, "/api/v1/executor/thread/messages", {:basic, :header}, body).status == 202
  end

  test "invalid sends are refused" do
    assert request(:post, "/api/v1/executor/thread/messages", grant(), %{text: "  ", client_request_id: "x"}).status == 422
    assert request(:post, "/api/v1/executor/thread/messages", grant(), %{text: "hi"}).status == 422
    assert request(:get, "/api/v1/executor/thread/messages?limit=500", grant()).status == 422
  end

  defp grant do
    {:ok, %{token: token}} = ThreadGrant.mint("kevin@ogm", secret: @secret)
    token
  end

  defp request(method, path, auth, body \\ nil) do
    conn = if body, do: conn(method, path, body), else: conn(method, path)
    conn = %{conn | secret_key_base: String.duplicate("s", 64), remote_ip: {127, 0, 0, 1}}
    conn = conn |> Plug.Session.call(@session) |> put_private(:aiur_dashboard_credentials, {"operator", "secret"}) |> put_private(:executor_thread_secret, @secret)

    conn =
      case auth do
        :basic -> put_req_header(conn, "authorization", "Basic " <> Base.encode64("operator:secret"))
        {:basic, :header} -> conn |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret")) |> put_req_header("x-aiur-request", "1")
        token when is_binary(token) -> put_req_header(conn, "authorization", "Bearer " <> token)
      end

    conn |> fetch_query_params() |> Router.call(Router.init([]))
  end
end
