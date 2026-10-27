defmodule Aiur.LoggerCrashReportTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  defmodule LargeStateServer do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_info(:crash, state), do: raise("intentional crash with large state #{length(state)}")
  end

  test "OTP crash reports bound inspection of large GenServer state" do
    assert Application.get_env(:logger, :translator_inspect_opts) == [
             limit: 100,
             printable_limit: 4_096,
             width: 120
           ]

    state = Enum.to_list(1..100_000)

    log =
      capture_log(fn ->
        Process.flag(:trap_exit, true)
        {:ok, pid} = LargeStateServer.start_link(state)
        send(pid, :crash)

        assert_receive {:EXIT, ^pid, _reason}, 5_000
      end)

    assert String.contains?(log, "intentional crash with large state 100000")
    assert byte_size(log) < 50_000
  end
end
