defmodule AiurWeb.ControlControllerGrantsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AiurWeb.Router

  @session_options Plug.Session.init(store: :cookie, key: "_aiur_control_grants_test", signing_salt: "aiur-test-session")
  @contract %{"contract" => "aiur.control.call", "contract_version" => 1}
  @peer "aaaaaaaaaaaaaaaaaaaaaaaaaa"

  setup do
    Aiur.TestSupport.start_owned_endpoint!()
    root = Path.join(System.tmp_dir!(), "control-grants-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    paths = %{client_tokens_path: Path.join(root, "tokens.json"), control_audit_file: Path.join(root, "audit.ndjson"), gateway_registry_path: Path.join(root, "remote-instances.yaml")}
    previous = Map.new(paths, fn {key, _} -> {key, Application.get_env(:aiur, key)} end)
    Enum.each(paths, fn {key, value} -> Application.put_env(:aiur, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:aiur, key)
        {key, value} -> Application.put_env(:aiur, key, value)
      end)

      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, token} = Aiur.ClientTokens.create("peer-token", "write", peer: @peer, categories: Aiur.ClientTokens.categories())
    %{token: token, registry: paths.gateway_registry_path, audit: paths.control_audit_file}
  end

  test "a peer granted only read is refused pause even with a token that holds every category", %{token: token, registry: registry} do
    write_registry(registry, "[read]")

    assert post_control(token, "Aiur.AgentControlCLI.status()").status == 200
    refused = post_control(token, "Aiur.AgentControlCLI.pause([\"999999\"])")
    assert refused.status == 403
    assert Jason.decode!(refused.resp_body)["error"]["code"] == "category_not_granted: agents"
  end

  test "an entry with no allows block permits read only", %{token: token, registry: registry} do
    File.write!(registry, "version: 1\ninstances:\n  nook:\n    gateway_id: \"#{@peer}\"\n")

    assert post_control(token, "Aiur.AgentControlCLI.status()").status == 200
    assert post_control(token, "Aiur.AgentControlCLI.pause([\"999999\"])").status == 403
  end

  test "a hand edit adding agents lets the peer call pause with no command run", %{token: token, registry: registry} do
    write_registry(registry, "[read]")
    assert post_control(token, "Aiur.AgentControlCLI.pause([\"999999\"])").status == 403

    write_registry(registry, "[read, agents]")
    assert post_control(token, "Aiur.AgentControlCLI.pause([\"999999\"])").status == 200
  end

  test "a peer with no registry entry is refused", %{token: token} do
    refused = post_control(token, "Aiur.AgentControlCLI.status()")
    assert refused.status == 403
    assert Jason.decode!(refused.resp_body)["error"]["code"] == "unknown_peer"
  end

  test "an invalid registry on first load refuses peer calls but not unbound tokens", %{token: token, registry: registry} do
    File.write!(registry, "version: 1\ninstances:\n  nook:\n    gateway_id: \"#{@peer}\"\n    token: abc\n")
    {:ok, unbound} = Aiur.ClientTokens.create("unbound", "read")

    refused = post_control(token, "Aiur.AgentControlCLI.status()")
    assert refused.status == 403
    assert Jason.decode!(refused.resp_body)["error"]["code"] == "grants_unavailable"
    assert post_control(unbound, "Aiur.AgentControlCLI.status()").status == 200
  end

  test "a token not listed in allows.credentials is refused", %{token: token, registry: registry} do
    File.write!(registry, "version: 1\ninstances:\n  nook:\n    gateway_id: \"#{@peer}\"\n    allows:\n      categories: [read]\n      credentials: [some-other-token]\n")

    assert post_control(token, "Aiur.AgentControlCLI.status()").status == 403
  end

  test "every grant-changing call over the control route is refused and audited, even for a fully granted peer", %{token: token, registry: registry, audit: audit} do
    write_registry(registry, "[read, message, executor, agents, tickets, config]")

    for call <- [
          "Aiur.Gateway.Cli.grant([peer: \"nook\", categories: [\"agents\"]])",
          "Aiur.Gateway.Cli.revoke([peer: \"nook\"])",
          "Aiur.Gateway.Cli.trust([peer: \"nook\", full: true])"
        ] do
      refused = post_control(token, call)
      assert refused.status == 403
      assert Jason.decode!(refused.resp_body)["error"]["code"] == "grants_are_local"
    end

    events = audit |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1) |> Enum.map(& &1["event"])
    assert events == List.duplicate("grants_are_local_refused", 3)
    assert File.read!(registry) =~ "[read, message, executor, agents, tickets, config]"
  end

  test "a refused category is audited with the peer and category", %{token: token, registry: registry, audit: audit} do
    write_registry(registry, "[read]")
    post_control(token, "Aiur.AgentControlCLI.pause([\"999999\"])")

    assert %{"event" => "category_not_granted_refused", "peer" => @peer, "category" => "agents"} =
             audit |> File.read!() |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
  end

  defp write_registry(path, categories) do
    File.write!(path, "version: 1\ninstances:\n  nook:\n    gateway_id: \"#{@peer}\"\n    allows:\n      categories: #{categories}\n")
  end

  defp post_control(token, expression) do
    payload = Map.put(@contract, "expression", expression)

    conn =
      :post
      |> conn("/api/v1/control", Jason.encode!(payload))
      |> Map.put(:secret_key_base, String.duplicate("s", 64))
      |> AiurWeb.Session.call(@session_options)
      |> fetch_session()
      |> put_req_header("content-type", "application/json")
      |> put_private(:aiur_dashboard_credentials, {"operator", "secret"})
      |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason))
      |> put_req_header("authorization", "Bearer " <> token)

    Router.call(conn, Router.init([]))
  end
end
