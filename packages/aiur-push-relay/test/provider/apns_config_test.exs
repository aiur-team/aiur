defmodule AiurPushRelay.Provider.ApnsConfigTest do
  use ExUnit.Case, async: false
  alias AiurPushRelay.Provider.Apns.Jwt
  alias AiurPushRelay.Provider.Registry
  import Plug.Test

  test "only readable mode 0600 P-256 private keys enable APNs" do
    path = Path.join(System.tmp_dir!(), "apns-key-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    {_, pem} = JOSE.JWK.generate_key({:ec, "P-256"}) |> JOSE.JWK.to_pem()
    File.write!(path, pem)
    File.chmod!(path, 0o600)

    env = %{
      "AIUR_RELAY_APNS_TEAM_ID" => "team",
      "AIUR_RELAY_APNS_KEY_ID" => "key",
      "AIUR_RELAY_APNS_KEY_FILE" => path
    }

    assert {:ok, %{team: "team", kid: "key"}} = Jwt.load(&Map.get(env, &1))
    File.chmod!(path, 0o644)
    assert {:error, :unavailable} = Jwt.load(&Map.get(env, &1))
    File.chmod!(path, 0o600)
    File.write!(path, "invalid")
    assert {:error, :unavailable} = Jwt.load(&Map.get(env, &1))
    {_, wrong_curve} = JOSE.JWK.generate_key({:ec, "P-384"}) |> JOSE.JWK.to_pem()
    File.write!(path, wrong_curve)
    assert {:error, :unavailable} = Jwt.load(&Map.get(env, &1))
    File.rm!(path)
    assert {:error, :unavailable} = Jwt.load(&Map.get(env, &1))
    assert {:error, :unavailable} = Jwt.load(fn _ -> nil end)
  end

  test "disabled provider reports unavailable and refuses APNs registration" do
    refute Registry.available?("apns")
    assert Registry.deliver(%{platform: "apns"}, %{}) == {:error, :provider_unavailable}
    assert Registry.deliver(%{platform: "fcm"}, %{}) == {:error, :provider_unavailable}
    opts = AiurPushRelay.Router.init(providers: Registry, pins: %{}, store: {__MODULE__, nil})
    health = conn(:get, "/healthz") |> AiurPushRelay.Router.call(opts)
    assert Jason.decode!(health.resp_body) == %{"store" => "ok", "apns" => "unavailable"}

    response =
      conn(:post, "/v1/handles", Jason.encode!(%{platform: "apns"}))
      |> AiurPushRelay.Router.call(opts)

    assert response.status == 503
    assert Jason.decode!(response.resp_body) == %{"error" => "provider_unavailable"}
  end

  def health(_), do: :ok

  test "enabled registry dispatches APNs and reports available" do
    key = JOSE.JWK.generate_key({:ec, "P-256"})

    start_supervised!(
      {Jwt, name: AiurPushRelay.ApnsJwt, config: %{key: key, team: "team", kid: "key"}}
    )

    old = Application.get_env(:aiur_push_relay, :apns)

    on_exit(fn ->
      if old,
        do: Application.put_env(:aiur_push_relay, :apns, old),
        else: Application.delete_env(:aiur_push_relay, :apns)
    end)

    owner = self()
    pin = %{"title" => "Aiur", "body" => "Open"}

    Application.put_env(:aiur_push_relay, :apns,
      jwt: AiurPushRelay.ApnsJwt,
      pins: %{"topic" => pin},
      transport: fn request ->
        send(owner, {:apns_request, request})
        {:ok, %{status: 410, body: ~s({"reason":"Unregistered"})}}
      end
    )

    assert Registry.available?("apns")
    row = %{platform: "apns", app_topic: "topic", environment: "sandbox", push_token: "device"}

    envelope = %{
      "ttl_s" => 0,
      "sealed" => "opaque",
      "kid" => "seal-key",
      "push_class" => "alert_normal"
    }

    assert Registry.deliver(row, envelope) == {:gone, "Unregistered"}
    assert_receive {:apns_request, request}, 1000
    assert Jason.decode!(request.body)["aps"]["alert"] == pin
    opts = AiurPushRelay.Router.init(providers: Registry, store: {__MODULE__, nil})
    response = conn(:get, "/healthz") |> AiurPushRelay.Router.call(opts)
    assert Jason.decode!(response.resp_body)["apns"] == "available"
  end
end
