defmodule Aiur.AppServerStderrCaptureTest.LogHandler do
  @moduledoc false

  def log(%{level: level, msg: message}, %{config: %{owner: owner} = config}) do
    rendered = render(message)
    send(owner, {:captured_app_server_log, level, rendered})
    if rendered == "Codex turn stream output: warning: this is stderr noise", do: File.write!(config.release_fifo, "continue\\n")
    :ok
  end

  def filesync(_handler_id), do: :ok

  defp render({:string, text}), do: IO.iodata_to_binary(text)
  defp render({format, args}), do: format |> :io_lib.format(args) |> IO.iodata_to_binary()
  defp render(message), do: inspect(message)
end

defmodule Aiur.AppServerStderrCaptureTest do
  use Aiur.TestSupport

  alias Aiur.AppServerStderrCaptureTest.LogHandler

  test "app server logs Codex stderr before returning completed turn" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-app-server-stderr")
    handler_id = :aiur_app_server_stderr_capture_test

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-92")
      codex_binary = Path.join(test_root, "fake-codex")
      release_fifo = Path.join(test_root, "release")
      File.mkdir_p!(workspace)
      assert {"", 0} = System.cmd("mkfifo", [release_fifo], stderr_to_stdout: true)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-92"}}}' ;;
          3) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-92"}}}' ;;
          4)
            printf '%s\\n' 'warning: this is stderr noise' >&2
            IFS= read -r release < "#{release_fifo}"
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, command: "#{codex_binary} app-server", agent_relay: false)

      issue = %Issue{
        id: "issue-stderr",
        identifier: "MT-92",
        title: "Capture stderr",
        description: "Ensure codex stderr is captured and logged",
        state: "In Progress",
        url: "https://example.org/issues/MT-92",
        labels: ["backend"]
      }

      assert :ok = :logger.add_handler(handler_id, LogHandler, %{config: %{owner: self(), release_fifo: release_fifo}})

      try do
        test_pid = self()

        on_message = fn message ->
          if message.event == :turn_completed do
            assert_received {:captured_app_server_log, :warning, "Codex turn stream output: warning: this is stderr noise"}
            send(test_pid, :turn_completed)
          end
        end

        assert {:ok, _result} = AppServer.run(workspace, "Capture stderr log", issue, on_message: on_message)
        assert_received :turn_completed
      after
        :logger.remove_handler(handler_id)
      end
    after
      Aiur.TestCleanup.rm_rf!(test_root)
    end
  end
end
