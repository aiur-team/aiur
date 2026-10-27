defmodule Aiur.CI.TransientNetworkFailureTest do
  use ExUnit.Case, async: true

  alias Aiur.CI.TransientNetworkFailure

  test "recognizes the supported network failure signatures" do
    for fixture <- ["checkout-connect.log", "hex-nxdomain.log", "httpc-failed-connect.log", "curl-resolve-host.log"] do
      assert TransientNetworkFailure.match?(fixture(fixture))
    end
  end

  test "does not retry ordinary ExUnit failures or a mixed network and test failure" do
    refute TransientNetworkFailure.match?("1) test creates a thing (ExampleTest)\nAssertion with == failed")

    refute TransientNetworkFailure.match?("Failed to connect to github.com\nExUnit: 1) test fails\nAssertion failed")
  end

  defp fixture(name), do: Path.join([__DIR__, "../../fixtures/ci_network", name]) |> Path.expand() |> File.read!()
end
