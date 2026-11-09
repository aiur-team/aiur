defmodule Aiur.ControlCall.ProjectTest do
  use ExUnit.Case, async: false

  alias Aiur.ControlCall
  alias Aiur.ControlCall.Allowlist
  alias Aiur.ControlCall.Project
  alias Aiur.Project.Context

  @b64_b Base.encode64("t311/b")

  describe "resolve/3" do
    test "explicit match wins, case-insensitively, in registry case" do
      assert Project.resolve("T311/B", nil, ["t311/a", "t311/b"]) == {:ok, "t311/b"}
    end

    test "two repos and nothing given is ambiguous; a hint breaks the tie only when it matches" do
      repos = ["t311/a", "t311/b"]
      assert Project.resolve(nil, nil, repos) == {:error, {:ambiguous, repos}}
      assert Project.resolve(nil, "t311/b", repos) == {:ok, "t311/b"}
      assert Project.resolve(nil, "x/y", repos) == {:error, {:ambiguous, repos}}
    end

    test "one repo ignores a hint and a matching project, and refuses a different project" do
      assert Project.resolve(nil, "x/y", ["t311/a"]) == {:ok, "t311/a"}
      assert Project.resolve("t311/a", nil, ["t311/a"]) == {:ok, "t311/a"}
      assert Project.resolve("t311/z", nil, ["t311/a"]) == {:error, {:unknown, "t311/z", ["t311/a"]}}
    end
  end

  describe "parse/2 and run/3" do
    test "project: and project_hint: are stripped before validation and carried on the call" do
      expr = ~s|Aiur.AgentControlCLI.queue(project: Base.decode64!("#{@b64_b}"), project_hint: Base.decode64!("#{Base.encode64("t311/a")}"), json: true)|
      assert {:ok, %{args: [[json: true]], project: {"t311/b", "t311/a"}}} = ControlCall.parse(expr, remote: true)
    end

    test "project: on a gateway-scoped function is refused" do
      expr = ~s|Aiur.AgentControlCLI.status(project: Base.decode64!("#{@b64_b}"), json: true)|
      assert {:error, :project_not_applicable} = ControlCall.parse(expr, remote: true)
    end

    test "set_setting accepts a remote call with no caller_cwd" do
      expr = ~s|Aiur.AgentControlCLI.set_setting("k", "1", project: Base.decode64!("#{@b64_b}"), caller_agent_workspace_env: "")|
      assert {:ok, %{project: {"t311/b", nil}}} = ControlCall.parse(expr, remote: true)
    end

    test "every project-scoped function exists in the allowlist" do
      for {segments, function} <- Project.project_scoped() do
        assert Enum.any?(Allowlist.entries(), fn {{s, f, _arity}, _} -> s == segments and f == function end),
               "#{inspect({segments, function})} is not allowlisted"
      end
    end
  end

  describe "against two registered projects" do
    setup do
      pids =
        for repo <- ["t311/a", "t311/b"] do
          project = Aiur.Project.from_machine_entry(%{repo: repo, config: "/x/config"}, "/x/state")
          parent = self()

          pid =
            spawn(fn ->
              Aiur.Project.Registry.register_root(project)
              send(parent, {:registered, repo})
              Process.sleep(:infinity)
            end)

          assert_receive {:registered, ^repo}, 1_000
          pid
        end

      on_exit(fn -> Enum.each(pids, &Process.exit(&1, :kill)) end)
      :ok
    end

    test "activate/2 puts the explicit project's context on the calling process" do
      assert :ok = Project.activate("t311/b", nil)
      assert Context.current_id() == "t311/b"
      Context.delete()
    end

    test "activate/2 without a project is an exit-64 style ambiguity listing the projects" do
      assert {:error, "pick a project: " <> listed} = Project.activate(nil, nil)
      assert listed =~ "t311/a, t311/b"
    end

    test "run/3 on an ambiguous project-scoped call exits 64 and runs nothing" do
      {:ok, parsed} = ControlCall.parse("Aiur.AgentControlCLI.queue(json: true)", remote: true)
      assert {:ok, output} = ControlCall.run(parsed, 5_000, "token:t")
      assert output =~ "pick a project: "
      assert output =~ "__AIUR_CONTROL_EXIT__:64"
    end
  end
end
