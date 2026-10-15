Code.require_file("../support/browser_harness/fixture_endpoint_start.ex", __DIR__)

defmodule Aiur.BrowserHarness.FixtureServerTest do
  use ExUnit.Case, async: true

  alias Aiur.BrowserHarness.FixtureEndpointStart

  test "an occupied fixture port is retried with an OS-assigned port" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, occupied_port}} = :inet.sockname(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)

    assert {:ok, {listener, assigned_port}} =
             FixtureEndpointStart.start(
               fn port ->
                 case :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}]) do
                   {:ok, listener} ->
                     {:ok, {{127, 0, 0, 1}, assigned_port}} = :inet.sockname(listener)
                     {:ok, {listener, assigned_port}}

                   {:error, :eaddrinuse} ->
                     linked_start_failure({
                       :shutdown,
                       {:failed_to_start_child, FixtureEndpoint, {:shutdown, {:failed_to_start_child, :listener, :eaddrinuse}}}
                     })

                   {:error, reason} ->
                     {:error, reason}
                 end
               end,
               occupied_port
             )

    on_exit(fn -> :gen_tcp.close(listener) end)

    assert assigned_port > 0
    refute assigned_port == occupied_port
  end

  defp linked_start_failure(reason) do
    pid = spawn_link(fn -> exit(reason) end)
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, ^reason}, 1_000
    {:ok, :collision}
  end
end
