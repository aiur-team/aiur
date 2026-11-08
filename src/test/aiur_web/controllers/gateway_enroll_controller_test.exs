defmodule AiurWeb.GatewayEnrollControllerTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest
  import Plug.Conn

  alias Aiur.ClientTokens
  alias Aiur.Gateway.{Invites, Registry}
  alias Aiur.Identity.Machine
  alias AiurWeb.Endpoint
  @endpoint Endpoint

  @path "/api/v1/gateway/enroll"
  @peer "aaaaaaaaaaaaaaaaaaaaaaaaaa"

  setup context do
    dir = Path.join(System.tmp_dir!(), "enroll-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    config = Application.get_env(:aiur, Endpoint)
    keys = [:gateway_registry_path, :control_audit_file, :client_tokens_path, :gateway_invites_path]
    previous = Map.new(keys, &{&1, Application.get_env(:aiur, &1)})
    machine_keys = [{Machine, :boot_result}, {Machine, :boot_context}]
    machine_previous = Map.new(machine_keys, &{&1, :persistent_term.get(&1, :absent)})

    Application.put_env(:aiur, :gateway_registry_path, Path.join(dir, "remote-instances.yaml"))
    Application.put_env(:aiur, :control_audit_file, Path.join(dir, "audit.ndjson"))
    Application.put_env(:aiur, :client_tokens_path, Path.join(dir, "tokens.json"))
    Application.put_env(:aiur, :gateway_invites_path, Path.join([dir, "invites", "invites.json"]))
    {:ok, _} = Machine.ensure(dir: Path.join(dir, "machine"))

    Application.put_env(
      :aiur,
      Endpoint,
      Keyword.merge(config || [], server: false, gateway_hello: Map.get(context, :hello, true), dashboard_writable: true, dashboard_auth_required: true, secret_key_base: String.duplicate("s", 64))
    )

    Aiur.TestSupport.start_owned_endpoint!()
    if is_nil(Process.whereis(AiurWeb.DashboardAuthRateLimit.Store)), do: start_supervised!(AiurWeb.DashboardAuthRateLimit.Store)
    # The limiter keys on the caller address, so each test gets its own.
    n = System.unique_integer([:positive])
    Process.put(:caller_ip, {10, rem(n, 250), rem(div(n, 250), 250), rem(div(n, 62_500), 250)})

    on_exit(fn ->
      Application.put_env(:aiur, Endpoint, config)
      for {k, v} <- previous, do: if(is_nil(v), do: Application.delete_env(:aiur, k), else: Application.put_env(:aiur, k, v))
      for {k, v} <- machine_previous, do: if(v == :absent, do: :persistent_term.erase(k), else: :persistent_term.put(k, v))
      File.chmod(Path.join(dir, "invites"), 0o700)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp invite(grants \\ ["read"], ttl \\ 600), do: elem(Invites.create(grants, ttl), 1)
  defp conn, do: %{build_conn() | remote_ip: Process.get(:caller_ip)}
  defp enroll(invite, over \\ %{}), do: post(conn(), @path, Map.merge(%{"id" => invite.id, "secret" => invite.secret, "gateway_id" => @peer, "label" => "Nook"}, over))
  defp peers, do: elem(Registry.get(), 1).peers
  defp tokens, do: elem(ClientTokens.list(), 1)

  test "a valid code enrols the peer: read entry, peer-bound token, burned invite" do
    conn = enroll(invite())
    body = json_response(conn, 200)
    assert body["granted"] == ["read"] and body["pending"] == []
    assert "aiur_" <> _ = body["token"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert %{categories: ["read"], gateway_id: @peer, label: "Nook", credentials: ["peer-Nook-1"]} = peers()["Nook"]
    assert [%{"name" => "peer-Nook-1", "peer" => @peer, "scope" => "read"}] = tokens()
    assert {:ok, %{peer: @peer}} = ClientTokens.authenticate_full(body["token"])
  end

  test "an invited write category is not written to the registry until a human confirms" do
    body = json_response(enroll(invite(["read", "message"])), 200)
    assert body["granted"] == ["read"] and body["pending"] == ["message"]
    assert peers()["Nook"].categories == ["read"]
    assert [%{"categories" => ["read", "message"]}] = tokens()
  end

  test "reuse is 410 invite_used and changes neither the registry nor the token store" do
    invite = invite()
    json_response(enroll(invite), 200)
    {registry, store} = {File.read!(Registry.path()), File.read!(Application.get_env(:aiur, :client_tokens_path))}

    assert %{"error" => "invite_used"} = json_response(enroll(invite, %{"gateway_id" => "bbbbbbbbbbbbbbbbbbbbbbbbbb"}), 410)
    assert {registry, store} == {File.read!(Registry.path()), File.read!(Application.get_env(:aiur, :client_tokens_path))}
  end

  test "an expired invite is 410 expired and writes nothing" do
    invite = elem(Invites.create(["read"], 1, System.os_time(:second) - 10), 1)
    assert %{"error" => "expired"} = json_response(enroll(invite), 410)
    assert peers() == %{} and tokens() == []
  end

  test "wrong secret and unknown id give the same 401 body and leave the invite usable" do
    invite = invite()
    wrong = json_response(enroll(invite, %{"secret" => "nope"}), 401)
    unknown = json_response(enroll(invite, %{"id" => "deadbeef"}), 401)
    assert wrong == unknown
    assert peers() == %{}
    json_response(enroll(invite), 200)
  end

  test "an already enrolled gateway id is 409 and the invite stays unused" do
    json_response(enroll(invite()), 200)
    second = invite()
    assert %{"error" => "duplicate_peer"} = json_response(enroll(second, %{"label" => "Other"}), 409)
    assert map_size(peers()) == 1
    assert json_response(enroll(second, %{"gateway_id" => "cccccccccccccccccccccccccc", "label" => "Other"}), 200)
  end

  test "a token minted for an unconfirmed write category cannot use a REST write route until the grant is confirmed" do
    token = json_response(enroll(invite(["read", "message"])), 200)["token"]

    messages = fn ->
      conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("origin", "http://127.0.0.1")
      |> put_req_header("x-aiur-request", "1")
      |> post("/api/v1/AIUR-1/messages", %{"message" => "hi"})
    end

    # The token's own scope allows messages; only the unconfirmed registry entry stops it.
    assert response(messages.(), 403) == "forbidden"

    # What GrantConfirmation writes once a signed-in human approves.
    :ok = Registry.write(fn instances -> put_in(instances, ["Nook", "allows", "categories"], ["read", "message"]) end, "test_confirmation")
    after_grant = messages.()
    refute after_grant.status in [401, 403], "got #{after_grant.status} #{inspect(after_grant.resp_body)} #{inspect(Registry.get())}"
  end

  test "an invite whose burn cannot be written is taken back: no peer, no token, and the answer is 503" do
    invite = invite()
    File.chmod!(Path.dirname(Application.get_env(:aiur, :gateway_invites_path)), 0o500)

    assert %{"error" => "unavailable"} = json_response(enroll(invite), 503)
    assert peers() == %{} and tokens() == []
  end

  test "the sixth attempt inside a minute is 429, even for a correct secret" do
    invite = invite()
    for _ <- 1..5, do: json_response(enroll(invite, %{"secret" => "nope"}), 401)
    assert %{"error" => "rate_limited"} = json_response(enroll(invite), 429)
    assert peers() == %{}
  end

  test "missing fields are 400 and a bad gateway id is refused" do
    assert json_response(post(conn(), @path, %{}), 400)
    assert json_response(enroll(invite(), %{"gateway_id" => "../x"}), 400)
  end

  @tag hello: false
  test "404 when server.gateway_hello hides the gateway" do
    assert enroll(invite()).status == 404
  end

  test "every refusal leaves an audit line with the reason and no secret" do
    invite = invite()
    enroll(invite, %{"secret" => "nope"})
    audit = File.read!(Application.get_env(:aiur, :control_audit_file))
    assert audit =~ "enroll_refused" and audit =~ "invalid_invite"
    refute audit =~ invite.secret
  end
end
