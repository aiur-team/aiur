defmodule AiurPushRelay.Provider.FcmTest do
  use ExUnit.Case, async: true
  alias AiurPushRelay.Provider.Fcm

  defmodule TokenExchange do
    def request(opts) do
      send(self_owner(), {:token_request, opts})
      {:ok, %{status: 200, body: %{"access_token" => "access-token", "expires_in" => 3600}}}
    end

    def self_owner, do: Process.get(:fcm_test_owner)
  end

  defp row, do: %{push_token: "device-token", platform: "fcm"}

  defp envelope(overrides \\ %{}) do
    Map.merge(
      %{"sealed" => "sealed-data", "kid" => "k_abc", "push_class" => "alert_high", "ttl_s" => 3600},
      overrides
    )
  end

  test "sends a data-only message with priority, seconds ttl and collapse class" do
    assert {:ok, payload} = Fcm.payload(row(), envelope())
    message = payload["message"]

    assert message["data"] == %{"s" => "sealed-data", "k" => "k_abc", "v" => "1"}
    refute Map.has_key?(message, "notification")
    assert message["android"] == %{"priority" => "HIGH", "ttl" => "3600s", "collapse_key" => "a"}
    assert {:ok, bytes} = Fcm.payload_size(row(), envelope())
    assert bytes == byte_size(Jason.encode!(payload))
  end

  test "normal alerts share collapse key b and normal priority" do
    assert {:ok, %{"message" => %{"android" => android}}} =
             Fcm.payload(row(), envelope(%{"push_class" => "alert_normal"}))

    assert android == %{"priority" => "NORMAL", "ttl" => "3600s", "collapse_key" => "b"}
  end

  test "rejects oversized outbound data before provider calls" do
    assert {:error, :payload_too_large} =
             Fcm.payload(row(), envelope(%{"sealed" => String.duplicate("x", 4096)}))

    assert Fcm.deliver_with(
             row(),
             envelope(%{"sealed" => String.duplicate("x", 4096)}),
             %{"project_id" => "test-project"},
             self(),
             fn _ -> flunk("oversized payload must not call Google") end
           ) == {:error, :payload_too_large}
  end

  test "maps FCM terminal, quota and provider failures" do
    unregistered =
      {:ok, %{status: 404, body: %{"error" => %{"details" => [%{"errorCode" => "UNREGISTERED"}]}}}}

    quota =
      {:ok,
       %{
         status: 429,
         headers: [{"retry-after", "17"}],
         body: %{"error" => %{"details" => [%{"errorCode" => "QUOTA_EXCEEDED"}]}}
       }}

    invalid =
      {:ok,
       %{status: 400, body: %{"error" => %{"details" => [%{"errorCode" => "INVALID_ARGUMENT"}]}}}}

    assert Fcm.map_response({:ok, %{status: 200}}) == :ok
    assert Fcm.map_response(unregistered) == {:gone, "UNREGISTERED"}
    assert Fcm.map_response(quota) == {:retry, 17_000}
    assert Fcm.map_response({:ok, %{status: 503}}) == {:retry, 60_000}
    assert Fcm.map_response(invalid) == {:error, {:invalid_argument, "INVALID_ARGUMENT"}}
  end

  test "OAuth access tokens are cached and refreshed five minutes before expiry" do
    {:ok, clock} = Agent.start_link(fn -> 1_000 end)
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    key = JOSE.JWK.generate_key({:rsa, 2048})
    owner = self()

    {:ok, server} =
      AiurPushRelay.Provider.Fcm.start_auth(
        %{
          "client_email" => "relay@example.test",
          "token_uri" => "https://oauth.example.test",
          "jwk" => key
        },
        request_fun: fn opts ->
          send(owner, {:token_request, opts})
          {:ok, %{status: 200, body: %{"access_token" => "access-token", "expires_in" => 3600}}}
        end,
        clock: fn -> Agent.get(clock, & &1) end,
        supervisor: supervisor
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    on_exit(fn -> if Process.alive?(clock), do: Agent.stop(clock) end)

    assert AiurPushRelay.Provider.Fcm.Auth.token(server) == {:ok, "access-token"}
    assert_receive {:token_request, initial_request}
    assert AiurPushRelay.Provider.Fcm.Auth.token(server) == {:ok, "access-token"}
    refute_receive {:token_request, _}, 50
    assert initial_request[:url] == "https://oauth.example.test"

    Agent.update(clock, &(&1 + 3_301))
    assert AiurPushRelay.Provider.Fcm.Auth.token(server) == {:ok, "access-token"}
    assert_receive {:token_request, request}
    assert request[:url] == "https://oauth.example.test"
    assert request[:body] =~ "urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer"
  end

  test "service account files with group or world permissions are rejected" do
    path = Path.join(System.tmp_dir!(), "fcm-account-#{System.unique_integer([:positive])}")
    File.write!(path, "{}")
    File.chmod!(path, 0o644)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    assert AiurPushRelay.Provider.Fcm.Auth.load(path) == {:error, :invalid_service_account}
  end
end
