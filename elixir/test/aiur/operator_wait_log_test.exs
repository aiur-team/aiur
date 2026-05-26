defmodule Aiur.OperatorWaitLogTest do
  use ExUnit.Case, async: false

  alias Aiur.OperatorWaitLog

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "operator_message_wait.ndjson")
    prev = Application.get_env(:aiur, :operator_wait_metrics_path)
    Application.put_env(:aiur, :operator_wait_metrics_path, path)

    on_exit(fn ->
      if is_nil(prev) do
        Application.delete_env(:aiur, :operator_wait_metrics_path)
      else
        Application.put_env(:aiur, :operator_wait_metrics_path, prev)
      end
    end)

    %{path: path}
  end

  test "metrics_file/0 returns the configured override path", %{path: path} do
    assert OperatorWaitLog.metrics_file() == path
  end

  test "record_delivered after record_queued appends one NDJSON line with wait_ms", %{path: path} do
    refute File.exists?(path)

    OperatorWaitLog.record_queued(42, "101", 48)
    # Give the system_time delta a non-zero tick to assert > 0 below.
    Process.sleep(5)
    OperatorWaitLog.record_delivered(42, "101")

    assert File.exists?(path)
    [line] = path |> File.read!() |> String.split("\n", trim: true)
    payload = Jason.decode!(line)

    assert payload["identifier"] == "101"
    assert payload["request_id"] == 42
    assert payload["text_bytes"] == 48
    assert is_integer(payload["wait_ms"])
    assert payload["wait_ms"] >= 0
    assert match?({:ok, _, _}, DateTime.from_iso8601(payload["at"]))
  end

  test "record_delivered without a prior record_queued is a silent no-op", %{path: path} do
    OperatorWaitLog.record_delivered(999, "404")

    refute File.exists?(path)
  end

  test "multiple delivered messages append in order", %{path: path} do
    OperatorWaitLog.record_queued(1, "100", 10)
    OperatorWaitLog.record_queued(2, "101", 20)
    OperatorWaitLog.record_delivered(1, "100")
    OperatorWaitLog.record_delivered(2, "101")

    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 2

    [first, second] = Enum.map(lines, &Jason.decode!/1)
    assert first["request_id"] == 1
    assert first["identifier"] == "100"
    assert second["request_id"] == 2
    assert second["identifier"] == "101"
  end
end
