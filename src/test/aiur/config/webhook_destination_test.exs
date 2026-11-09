defmodule Aiur.Config.WebhookDestinationTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.WebhookDestination

  test "rejects sensitive literal address ranges by default" do
    destinations = [
      loopback: "127.0.0.1",
      ipv6_loopback: "[::1]",
      link_local: "169.254.1.10",
      metadata: "169.254.169.254",
      rfc1918_10: "10.0.0.1",
      rfc1918_172: "172.16.0.1",
      rfc1918_192: "192.168.0.1",
      cgnat: "100.64.0.1",
      ula: "[fd00::1]",
      unspecified_v4: "0.0.0.0",
      unspecified_v6: "[::]",
      mapped_private_v4: "[::ffff:127.0.0.1]"
    ]

    for {class, host} <- destinations do
      assert {:error, message} = WebhookDestination.validate_url("https://#{host}/events", false), to_string(class)
      assert message =~ "must not use", to_string(class)
    end
  end

  test "allows an explicitly opted-in private literal for trusted development" do
    assert :ok = WebhookDestination.validate_url("https://127.0.0.1/events", true)
  end

  test "private opt-in does not allow unspecified destinations" do
    for host <- ["0.0.0.0", "0.1.2.3", "[::]", "[::ffff:0.0.0.0]"] do
      assert {:error, message} = WebhookDestination.validate_url("https://#{host}/events", true)
      assert message =~ "must not use"
    end

    resolver = fn "consumer.example.test" -> {:ok, [{0, 0, 0, 0}]} end

    assert {:error, :private_destination_forbidden} =
             WebhookDestination.resolve("https://consumer.example.test/events", true, resolver)
  end

  test "rejects a hostname when DNS returns any private address" do
    resolver = fn "consumer.example.test" -> {:ok, [{93, 184, 216, 34}, {10, 0, 0, 8}]} end

    assert {:error, :private_destination_forbidden} =
             WebhookDestination.resolve("https://consumer.example.test/events", false, resolver)
  end

  test "pins a public DNS result while preserving the TLS and Host identity" do
    resolver = fn "consumer.example.test" -> {:ok, [{93, 184, 216, 34}]} end

    assert {:ok, "https://93.184.216.34/events?tenant=mobile", "consumer.example.test"} =
             WebhookDestination.resolve("https://consumer.example.test/events?tenant=mobile", false, resolver)
  end
end
