defmodule Aiur.Experiments.Sources.ScriptTest do
  use ExUnit.Case, async: false
  alias Aiur.Experiments.{Metric, Sources.Script}

  @window %{start: ~U[2026-01-01 10:00:00Z], end: ~U[2026-01-01 13:00:00Z]}
  @fixture Path.expand("../../../fixtures/experiments/consumer_repo", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "metric-script-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{root: root}
  end

  test "fixture script emits numeric observations inside its requested window" do
    result = Script.observations(metric(["/bin/sh", "bin/latency.sh"]), "app/request_latency", @window, %{repo_path: @fixture})
    assert result.coverage.state == :captured
    assert Enum.map(result.observations, &{&1.unit_id, &1.value, &1.at}) == [{"request-1", 42, @window.start}, {"request-2", 57, @window.start}]
  end

  test "timeout stops the child process and its descendants", %{root: root} do
    path = write_script(root, "sleep 30 &\nprintf '%s\\n' \"$!\" > process.pid\nsleep 30\n")
    result = Script.observations(metric(["/bin/sh", path]), "app/request_latency", @window, %{repo_path: root, script_timeout_ms: 1_000})
    assert result == %{coverage: %{state: :unavailable, reason: :timeout}, observations: []}
    child_pid = Path.join(root, "process.pid") |> File.read!() |> String.trim() |> String.to_integer()
    refute Aiur.ProcessTree.process_alive?(child_pid)
  end

  test "continuous output cannot starve the timeout", %{root: root} do
    path = write_script(root, "while :; do printf x; done\n")
    result = Script.observations(metric(["/bin/sh", path]), "app/request_latency", @window, %{repo_path: root, script_timeout_ms: 20})
    assert result == %{coverage: %{state: :unavailable, reason: :timeout}, observations: []}
  end

  test "nonzero exit carries first error line, and overflowing stdout is bounded", %{root: root} do
    path = write_script(root, "printf 'measurement failed\\nmore details\\n' >&2\nexit 2\n")

    assert %{coverage: %{state: :unavailable, reason: {:exit_status, 2, "measurement failed"}}, observations: []} =
             Script.observations(metric(["/bin/sh", path]), "app/request_latency", @window, %{repo_path: root})

    write_script(root, "while :; do printf '0123456789'; done\n")

    assert %{coverage: %{state: :unavailable, reason: :output_too_large}, observations: []} =
             Script.observations(metric(["/bin/sh", path]), "app/request_latency", @window, %{repo_path: root, script_output_limit: 128})
  end

  test "default output cap rejects a stream larger than eight megabytes", %{root: root} do
    path = write_script(root, "dd if=/dev/zero bs=1048576 count=9 2>/dev/null\n")
    assert %{coverage: %{state: :unavailable, reason: :output_too_large}, observations: []} = Script.observations(metric(["/bin/sh", path]), "app/request_latency", @window, %{repo_path: root})
  end

  test "credentials and shell startup are scrubbed; window variables are passed", %{root: root} do
    names = ~w(
      GITHUB_TOKEN GH_TOKEN OPENAI_API_KEY GITHUB_APP_CLIENT_SECRET AIUR_SUPERVISOR_TOKEN AIUR_CI_READINESS_TOKEN
      ERL_CRASH_DUMP ERL_CRASH_DUMP_SECONDS BASH_ENV ENV
    )
    saved = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.put_env(&1, "must-not-leak"))
    on_exit(fn -> Enum.each(saved, fn {name, value} -> if value, do: System.put_env(name, value), else: System.delete_env(name) end) end)
    checks = Enum.map_join(names, "\n", fn name -> "test -z \"${#{name}:-}\" || exit 3" end)
    path = write_script(root, checks <> "\ntest \"$AIUR_EXPERIMENT_METRIC\" = app/request_latency\n" <> ~S(printf '{"unit_id":"clean","value":1,"at":"%s"}\n' "$AIUR_EXPERIMENT_WINDOW_START"))

    assert %{coverage: %{state: :captured}, observations: [%{unit_id: "clean", value: 1}]} =
             Script.observations(metric(["/bin/sh", path]), "app/request_latency", @window, %{repo_path: root})
  end

  test "argv is literal and zero samples from a successful script are captured", %{root: root} do
    path = write_script(root, "test \"$1\" = '$(touch injected)' || exit 3\n")

    assert %{coverage: %{state: :captured}, observations: []} =
             Script.observations(metric(["/bin/sh", path, "$(touch injected)"]), "app/request_latency", @window, %{repo_path: root})

    refute File.exists?(Path.join(root, "injected"))
  end

  defp metric(argv), do: %Metric{requires: [], source: %{"kind" => "script", "argv" => argv, "cwd" => "repo"}}

  defp write_script(root, body) do
    path = Path.join(root, "measure.sh")
    File.write!(path, "#!/bin/sh\nset -eu\n" <> body)
    path
  end
end
