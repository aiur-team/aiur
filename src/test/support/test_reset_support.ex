defmodule Aiur.TestResetSupport do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Aiur.TestResetSupport, only: [with_env: 2, write_reset_fixture!: 1, write_reset_fixture!: 2]
    end
  end

  setup do
    tmp_dir = Aiur.TestSupport.tmp_root!("aiur_test_reset")
    File.mkdir_p!(tmp_dir)

    previous_agent_workspace = System.get_env("AIUR_AGENT_WORKSPACE")
    previous_agent_ir_sandbox = System.get_env("AIUR_AGENT_IR_SANDBOX")
    System.delete_env("AIUR_AGENT_WORKSPACE")
    System.delete_env("AIUR_AGENT_IR_SANDBOX")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      restore_system_env("AIUR_AGENT_WORKSPACE", previous_agent_workspace)
      restore_system_env("AIUR_AGENT_IR_SANDBOX", previous_agent_ir_sandbox)
    end)

    %{tmp_dir: tmp_dir}
  end

  def with_env(overrides, fun) do
    previous = Map.new(overrides, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(overrides, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  def write_reset_fixture!(tmp, tickets \\ [101, 102, 103]) do
    File.mkdir_p!(Path.join(tmp, "src/lib/aiur/sandbox"))

    {_, 0} = System.cmd("git", ["init"], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: tmp)

    for name <- [
          "event_flow_demo.ex",
          "event_flow_unrelated_1.ex",
          "event_flow_unrelated_2.ex",
          "event_flow_unrelated_3.ex"
        ] do
      File.write!(Path.join([tmp, "src/lib/aiur/sandbox", name]), "defmodule X do\nend\n")
    end

    File.write!(Path.join(tmp, ".aiur-test-tickets.json"), Jason.encode!(%{"tickets" => tickets}))

    {_, 0} = System.cmd("git", ["add", "."], cd: tmp)
    {_, 0} = System.cmd("git", ["commit", "-m", "baseline"], cd: tmp)
  end
end
