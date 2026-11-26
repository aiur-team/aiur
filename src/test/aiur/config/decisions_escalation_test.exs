defmodule Aiur.Config.DecisionsEscalationTest do
  use ExUnit.Case, async: false

  alias Aiur.Config
  alias Aiur.Config.Schema
  alias Aiur.Workflow

  setup do
    previous = Application.get_env(:aiur, :workflow_file_path)
    dir = Aiur.TestSupport.tmp_root!("decisions-escalation")
    File.mkdir_p!(dir)
    path = Path.join(dir, "config")
    File.write!(path, "tracker: {kind: memory}\n")
    Workflow.set_workflow_file_path(path)

    on_exit(fn ->
      if is_nil(previous), do: Workflow.clear_workflow_file_path(), else: Workflow.set_workflow_file_path(previous)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{path: path}
  end

  test "absent and empty escalation sections expose defaults" do
    for attrs <- [%{}, %{"decisions" => %{}}, config(%{})] do
      assert {:ok, settings} = Schema.parse(attrs)

      assert Map.take(settings.decisions.escalation, [:enabled, :executor_ack_ms, :executor_answer_ms, :urgent_factor]) ==
               %{enabled: true, executor_ack_ms: 300_000, executor_answer_ms: 900_000, urgent_factor: 0.5}
    end

    assert Config.decision_escalation() == %{enabled: true, ack_ms: 300_000, answer_ms: 900_000, urgent_factor: 0.5}
  end

  test "YAML overrides and reload reach the public accessor", %{path: path} do
    for {enabled, ack_ms, answer_ms, factor} <- [{false, 10_000, 10_000, 1.0}, {true, 20_000, 40_000, 0.25}] do
      File.write!(path, """
      tracker: {kind: memory}
      decisions:
        escalation:
          enabled: #{enabled}
          executor_ack_ms: #{ack_ms}
          executor_answer_ms: #{answer_ms}
          urgent_factor: #{factor}
      """)

      assert :ok = Aiur.WorkflowStore.force_reload()
      assert Config.decision_escalation() == %{enabled: enabled, ack_ms: ack_ms, answer_ms: answer_ms, urgent_factor: factor}
    end
  end

  test "acknowledgement below minimum is rejected" do
    assert_error(%{"executor_ack_ms" => 9_999}, "executor_ack_ms")
  end

  test "answer below acknowledgement is rejected including partial overrides" do
    assert_error(%{"executor_answer_ms" => 299_999}, "executor_answer_ms")
    assert_error(%{"executor_ack_ms" => 900_001}, "executor_answer_ms")
  end

  test "urgent factor outside its range is rejected" do
    for factor <- [-0.1, 0, 1.01], do: assert_error(%{"urgent_factor" => factor}, "urgent_factor")
  end

  test "invalid types name the offending field" do
    for key <- ["enabled", "executor_ack_ms", "executor_answer_ms", "urgent_factor"] do
      assert_error(%{key => "invalid"}, key)
    end
  end

  defp config(attrs), do: %{"decisions" => %{"escalation" => attrs}}

  defp assert_error(attrs, key) do
    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config(attrs))
    assert message =~ "decisions.escalation.#{key}"
  end
end
