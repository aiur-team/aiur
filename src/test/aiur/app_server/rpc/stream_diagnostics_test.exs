defmodule Aiur.AppServer.Rpc.StreamDiagnosticsTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.Rpc.StreamDiagnostics

  setup do
    %{port: cat_port()}
  end

  test "retains recent lines oldest first", %{port: port} do
    StreamDiagnostics.record(port, "first\n")
    StreamDiagnostics.record(port, "  second  ")

    assert StreamDiagnostics.recent_text(port) == "first\nsecond"
  end

  test "keeps only the most recent lines", %{port: port} do
    Enum.each(1..25, &StreamDiagnostics.record(port, "line-#{&1}"))

    lines = port |> StreamDiagnostics.recent_text() |> String.split("\n")

    assert length(lines) == 20
    assert List.first(lines) == "line-6"
    assert List.last(lines) == "line-25"
  end

  test "truncates an oversized line", %{port: port} do
    StreamDiagnostics.record(port, String.duplicate("x", 5_000))

    assert String.length(StreamDiagnostics.recent_text(port)) == 1_000
  end

  test "ignores blank lines", %{port: port} do
    StreamDiagnostics.record(port, "   \n")

    assert StreamDiagnostics.recent_text(port) == ""
  end

  test "is scoped per port", %{port: port} do
    other = cat_port()

    StreamDiagnostics.record(port, "mine")
    StreamDiagnostics.record(other, "theirs")

    assert StreamDiagnostics.recent_text(port) == "mine"
    assert StreamDiagnostics.recent_text(other) == "theirs"
  end

  test "clear drops the retained lines", %{port: port} do
    StreamDiagnostics.record(port, "stale banner")
    StreamDiagnostics.clear(port)

    assert StreamDiagnostics.recent_text(port) == ""
  end

  test "tolerates a non-port target" do
    assert StreamDiagnostics.record(:not_a_port, "line") == :ok
    assert StreamDiagnostics.recent_text(:not_a_port) == ""
    assert StreamDiagnostics.clear(:not_a_port) == :ok
  end

  defp cat_port do
    port =
      Port.open({:spawn_executable, String.to_charlist(System.find_executable("cat"))}, [
        :binary,
        :exit_status,
        line: 64_000
      ])

    on_exit(fn ->
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end)

    port
  end
end
