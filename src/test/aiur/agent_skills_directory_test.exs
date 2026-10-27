defmodule Aiur.AgentSkillsDirectoryTest do
  use ExUnit.Case, async: false

  test "installation creates each missing directory once without retrying existing ancestors" do
    workspace = Aiur.TestSupport.tmp_root!("skills-directory")
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

    caller = self()
    collector = Task.async(fn -> collect_directories(caller, []) end)
    on_exit(fn -> :erlang.trace_pattern({:file, :make_dir, 1}, false, []) end)
    :erlang.trace_pattern({:file, :make_dir, 1}, true, [])
    :erlang.trace(caller, true, [:call, {:tracer, collector.pid}])

    try do
      assert :ok = Aiur.AgentSkills.install(workspace)
    after
      :erlang.trace_pattern({:file, :make_dir, 1}, false, [])
      :erlang.trace(caller, false, [:call])
      delivered = :erlang.trace_delivered(caller)
      assert_receive {:trace_delivered, ^caller, ^delivered}, 1_000
      send(collector.pid, :done)
    end

    directories = Task.await(collector)
    assert directories != []
    assert Enum.all?(directories, &String.starts_with?(&1, workspace <> "/"))
    assert length(directories) == length(Enum.uniq(directories))
    assert File.regular?(Path.join(workspace, ".claude/skills/aiur-experiment/SKILL.md"))
  end

  defp collect_directories(caller, directories) do
    receive do
      {:trace, ^caller, :call, {:file, :make_dir, [path]}} ->
        collect_directories(caller, [IO.chardata_to_string(path) | directories])

      :done ->
        directories
    end
  end
end
