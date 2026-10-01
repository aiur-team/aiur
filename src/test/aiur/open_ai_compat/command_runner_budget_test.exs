defmodule Aiur.OpenAICompat.CommandRunnerBudgetTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentGitHubGuard
  alias Aiur.GitHub.Budget
  alias Aiur.OpenAICompat.CommandRunner

  setup do
    if is_nil(Process.whereis(Aiur.TaskSupervisor)) do
      start_supervised!({Task.Supervisor, name: Aiur.TaskSupervisor})
    end

    root = Aiur.TestSupport.tmp_root!("aiur-command-budget")
    workspace = Path.join(root, "workspace")
    budget = Path.join(root, "host-budget")
    File.mkdir_p!(workspace)
    File.mkdir_p!(budget)
    previous_budget = Application.get_env(:aiur, :github_budget_dir)
    previous_enabled = Application.get_env(:aiur, :github_budget_enabled?)

    Application.put_env(:aiur, :github_budget_dir, budget)
    Application.put_env(:aiur, :github_budget_enabled?, true)

    on_exit(fn ->
      restore_env(:github_budget_dir, previous_budget)
      restore_env(:github_budget_enabled?, previous_enabled)
      File.rm_rf(root)
    end)

    {:ok, workspace: workspace, budget: budget}
  end

  test "binds only the host-shared GitHub budget state into agent commands", %{workspace: workspace, budget: budget} do
    parent = self()

    runner = fn executable, args, opts ->
      send(parent, {:command, executable, args, opts})
      {"ok", 0}
    end

    assert %{"success" => true} =
             CommandRunner.run(workspace, "echo safe", sandbox_executable: "/usr/bin/bwrap", system_cmd: runner)

    assert_receive {:command, "/usr/bin/bwrap", args, [stderr_to_stdout: true]}, 1000
    triples = Enum.chunk_every(args, 3, 1, :discard)

    assert Enum.member?(triples, ["--bind", budget, budget])
    assert Enum.member?(triples, ["--setenv", "AIUR_GITHUB_BUDGET_ROOT", budget])
    refute ["--bind", System.user_home!(), System.user_home!()] in triples
  end

  test "does not pass daemon GitHub credentials into the command sandbox", %{workspace: workspace} do
    previous = for name <- ~w(GITHUB_TOKEN GH_TOKEN), into: %{}, do: {name, System.get_env(name)}
    System.put_env("GITHUB_TOKEN", "host-github-token-sentinel")
    System.put_env("GH_TOKEN", "host-gh-token-sentinel")

    on_exit(fn ->
      for {name, value} <- previous, do: restore_env(name, value)
    end)

    parent = self()

    runner = fn executable, args, opts ->
      send(parent, {:command, executable, args, opts})
      {"ok", 0}
    end

    assert %{"success" => true} =
             CommandRunner.run(workspace, "echo safe", sandbox_executable: "/usr/bin/bwrap", system_cmd: runner)

    assert_receive {:command, "/usr/bin/bwrap", args, [stderr_to_stdout: true]}, 1000
    assert "--clearenv" in args

    for name <- ~w(GITHUB_TOKEN GH_TOKEN) do
      refute ["--setenv", name] in Enum.chunk_every(args, 2, 1, :discard)
    end

    refute "host-github-token-sentinel" in args
    refute "host-gh-token-sentinel" in args

    assert ["--setenv", "AIUR_GITHUB_CREDENTIAL_FILE", AgentGitHubGuard.agent_token_path()] in Enum.chunk_every(args, 3, 1, :discard)
  end

  test "a real sandbox writes to the host-shared budget database", %{workspace: workspace, budget: budget} do
    case System.find_executable("bwrap") do
      nil ->
        :ok

      bwrap ->
        :ok = AgentGitHubGuard.install(workspace)
        token = "sandbox-shared-token"

        command =
          "python3 \"$AIUR_GITHUB_BUDGET_BROKER\" acquire --resource core --consumer-key sandbox " <>
            "--endpoint-family issues --max-inflight 2 --max-inflight-per-endpoint 2 " <>
            "--requests-per-minute 20 --stagger-ms 0 --lease-ttl-ms 35000 " <>
            "--db \"$AIUR_GITHUB_BUDGET_ROOT/budget.sqlite3\" --token-key \"#{Budget.token_key(token)}\""

        assert %{"success" => true, "output" => "granted " <> _lease} =
                 CommandRunner.run(workspace, command, sandbox_executable: bwrap)

        assert %{"issues" => 1} = Budget.snapshot(token, state_dir: budget, enabled?: true).inflight
    end
  end

  test "a direct system gh API path is intercepted by the workspace guard", %{workspace: workspace, budget: budget} do
    case {System.find_executable("bwrap"), Enum.find(~w(/usr/bin/gh /usr/local/bin/gh), &File.regular?/1)} do
      {bwrap, _target} when is_binary(bwrap) ->
        fake_bin = workspace |> Path.dirname() |> Path.join("custom-bin")
        fake_gh = Path.join(fake_bin, "gh")
        calls = Path.join(workspace, "direct-gh-calls")
        File.mkdir_p!(fake_bin)
        File.write!(fake_gh, "#!/bin/sh\nprintf '%s\\n' \"$*\" > #{calls}\nprintf 'guarded\\n'\n")
        File.chmod!(fake_gh, 0o755)
        old_path = System.get_env("PATH")
        System.put_env("PATH", fake_bin <> ":" <> old_path)

        on_exit(fn ->
          System.put_env("PATH", old_path)
        end)

        :ok = AgentGitHubGuard.install(workspace)
        :ok = AgentGitHubGuard.ensure_agent_token_file(token: "sandbox-absolute-token")

        assert %{"success" => true, "output" => "guarded\n"} =
                 CommandRunner.run(workspace, "#{fake_gh} api repos/owner/repo/issues/1477", sandbox_executable: bwrap)

        assert File.read!(calls) == "api repos/owner/repo/issues/1477 --include\n"
        assert [_admission] = Budget.snapshot("sandbox-absolute-token", state_dir: budget, enabled?: true).admissions

      _unavailable ->
        :ok
    end
  end

  test "refuses a sandbox command when the shared budget state cannot be mounted", %{workspace: workspace, budget: budget} do
    File.rm_rf!(budget)
    File.write!(budget, "not a directory")
    parent = self()

    runner = fn _executable, _args, _opts ->
      send(parent, :sandbox_started)
      {"ok", 0}
    end

    assert %{"success" => false, "output" => "shared GitHub budget state unavailable"} =
             CommandRunner.run(workspace, "echo unsafe", sandbox_executable: "/usr/bin/bwrap", system_cmd: runner)

    refute_receive :sandbox_started
  end

  defp restore_env(key, nil) when is_atom(key), do: Application.delete_env(:aiur, key)
  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value) when is_atom(key), do: Application.put_env(:aiur, key, value)
  defp restore_env(key, value), do: System.put_env(key, value)
end
