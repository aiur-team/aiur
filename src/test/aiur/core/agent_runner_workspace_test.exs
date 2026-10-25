defmodule Aiur.Core.AgentRunnerWorkspaceTest do
  use Aiur.TestSupport

  test "agent runner keeps workspace after successful codex run" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-agent-runner-retain-workspace")

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      # Linear default config namespaces workspaces under <root>/<project_slug>/,
      # so the issue dir lands in workspace_root/project/, not directly under root.
      repo_dir = Path.join(workspace_root, "project")
      before = if File.dir?(repo_dir), do: MapSet.new(File.ls!(repo_dir)), else: MapSet.new()
      assert :ok = AgentRunner.run(issue)

      created = MapSet.difference(MapSet.new(File.ls!(repo_dir)), before)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(repo_dir, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner sends before_run conflict filenames in the first turn/start input" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-agent-runner-conflict-prompt")

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      identifier = "MT-CONFLICT-PROMPT-#{System.unique_integer([:positive])}"

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test\n")
      {_, 0} = System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      {_, 0} = System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      {_, 0} = System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", template_repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file=#{inspect(trace_file)}
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        request_id=$(printf '%s' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p')
        case "$line" in
          *'"method":"initialize"'*)
            printf '{"id":%s,"result":{}}\\n' "$request_id"
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '{"id":%s,"result":{"thread":{"id":"thread-conflict-prompt"}}}\\n' "$request_id"
            ;;
          *'"method":"turn/start"'*)
            printf '{"id":%s,"result":{"turn":{"id":"turn-conflict-prompt"}}}\\n' "$request_id"
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        hook_before_run: """
        mkdir -p logs
        printf '%s\\n' '## Conflicting files' '- lib/from-base.ex' > logs/before-run-merge-conflict.md
        """,
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      workspace = Path.join([workspace_root, "project", identifier])
      File.mkdir_p!(workspace)
      {_, 0} = System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      {_, 0} = System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      {_, 0} = System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      File.write!(Path.join(workspace, "README.md"), "# existing workspace\n")
      {_, 0} = System.cmd("git", ["-C", workspace, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", workspace, "commit", "-m", "existing workspace"])

      issue = %Issue{
        id: "issue-conflict-prompt",
        identifier: identifier,
        title: "Resolve preflight merge conflict",
        description: "The first provider turn must be told which files conflict.",
        state: "In Progress",
        url: "https://example.org/issues/MT-CONFLICT-PROMPT",
        labels: []
      }

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      assert File.read!(Path.join([workspace, "logs", "before-run-merge-conflict.md"])) =~ "lib/from-base.ex"

      turn_start =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["method"] == "turn/start"))

      first_turn_text = get_in(turn_start, ["params", "input"]) |> Enum.map_join("\n", &Map.get(&1, "text", ""))
      assert first_turn_text =~ "- `lib/from-base.ex`"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-agent-runner-updates")

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"

      workspace = Path.join([workspace_root, "project", "MT-99"])
      ndjson_log = Path.join(workspace, "logs/agent.ndjson")
      markdown_log = Path.join(workspace, "logs/agent.md")

      assert File.exists?(ndjson_log)
      assert File.exists?(markdown_log)

      assert File.read!(ndjson_log) =~ "\"event\":\"session_started\""
      assert File.read!(ndjson_log) =~ "\"event\":\"turn_completed\""
      assert File.read!(markdown_log) =~ "session_started"
      assert File.read!(markdown_log) =~ "turn_completed"
    after
      File.rm_rf(test_root)
    end
  end
end
