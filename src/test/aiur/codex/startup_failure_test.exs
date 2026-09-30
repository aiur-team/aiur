defmodule Aiur.Codex.StartupFailureTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Codex.{CodingAgent, StartupFailure}
  alias Aiur.Config.Paths

  test "a process exiting before initialize persists its status and a redacted bounded diagnostic" do
    root = Aiur.TestSupport.tmp_root!("startup-failure")
    File.mkdir_p!(root)
    workspace = Path.join(Aiur.Config.workspace_root(), "startup-failure")
    File.mkdir_p!(workspace)
    script = Path.join(root, "failing-app-server")

    File.write!(
      script,
      "#!/bin/sh\nprintf '%s\\n' 'fatal: startup refused' 'API key abc123' 'Authorization: Bearer visible-secret' '{\"id\":1,\"authorization\":\"visible-secret\"}'\nexit 23\n"
    )

    File.chmod!(script, 0o700)
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), codex_command: script)

    assert {:error, {:port_exit, 23}} =
             CodingAgent.start_session(workspace, identifier: "2895", attempt_id: "2895:test")

    path = Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.2895.startup-failures.ndjson")
    assert {:ok, body} = File.read(path)
    [record] = body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert record["ticket"] == "2895"
    assert record["attempt_id"] == "2895:test"
    assert record["exit_status"] == 23
    assert record["diagnostic"] =~ "fatal: startup refused"
    refute body =~ "visible-secret"
    refute body =~ "abc123"
    refute body =~ "authorization"
    assert byte_size(record["diagnostic"]) <= 1_000
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    refute File.exists?(Path.join(workspace, "logs/agent.ndjson"))
  end

  test "diagnostics drop protocol frames and cap lengthy output" do
    text = ~s({"id":1,"result":{"token":"hidden"}}\n) <> String.duplicate("lengthy output ", 200)
    excerpt = StartupFailure.safe_excerpt(text)
    refute excerpt =~ "hidden"
    assert String.length(excerpt) == 250
    assert byte_size(excerpt) <= 1_000
  end

  test "diagnostics redact a spaced API key label" do
    secret = "abc123"
    excerpt = StartupFailure.safe_excerpt("fatal: API key #{secret} was rejected")

    assert excerpt == "[redacted sensitive output]"
    refute excerpt =~ secret
  end

  test "diagnostic file is private before the first and subsequent append" do
    path = Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.private-startup.startup-failures.ndjson")
    File.mkdir_p!(Path.dirname(path))
    parent = self()

    writer = fn destination, line ->
      send(parent, {:mode_at_write, Bitwise.band(File.stat!(destination).mode, 0o777)})
      File.write(destination, line, [:append])
    end

    StartupFailure.record_with_writer("private-startup", "attempt-1", 23, "startup refused", writer)
    assert_received {:mode_at_write, 0o600}

    File.chmod!(path, 0o644)
    StartupFailure.record_with_writer("private-startup", "attempt-2", 23, "startup refused", writer)
    assert_received {:mode_at_write, 0o600}
  end
end
