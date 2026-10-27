defmodule Aiur.Codex.NativeCaptureLaunchTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Codex.AppServerPort
  alias Aiur.Harness.Capabilities

  @command "wrapper codex app-server --config features.default_mode_request_user_input=false"
  @flag " --config features.default_mode_request_user_input=true"

  test "gate off preserves custom command and overrides byte for byte (compatibility guard)" do
    configure(false)
    assert AppServerPort.codex_command_for_test(nil) == @command

    assert AppServerPort.codex_command_for_test("gpt-5.5", "high") ==
             @command <> " --config 'model=\"gpt-5.5\"' --config 'model_reasoning_effort=\"high\"'"

    assert {:ok, %{native_question: :none, native_question_reason: :gate_off}} = Capabilities.delivery_primitives("codex")
  end

  test "gate on appends a trailing boolean after a custom command" do
    configure(true)
    assert AppServerPort.codex_command_for_test(nil) == @command <> @flag
  end

  test "gate on keeps model and effort overrides before the last boolean config" do
    configure(true)

    assert AppServerPort.codex_command_for_test("gpt-5.5", "high") ==
             @command <> " --config 'model=\"gpt-5.5\"' --config 'model_reasoning_effort=\"high\"'" <> @flag
  end

  test "delivery capability follows gate reloads and retains unrelated harness defaults" do
    configure(true)
    assert {:ok, %{native_question: :in_band_hold, native_question_reason: nil}} = Capabilities.delivery_primitives("codex")
    assert {:ok, %{native_question: :none}} = Capabilities.delivery_primitives("claude")

    configure(false)
    assert {:ok, %{native_question: :none, native_question_reason: :gate_off}} = Capabilities.delivery_primitives("codex")
  end

  defp configure(enabled) do
    write_workflow_file!(Workflow.workflow_file_path(), codex_command: @command)
    path = Workflow.workflow_file_path()
    File.write!(path, File.read!(path) <> "\ndecisions: {native_capture: {codex: #{enabled}}}\n")
    assert :ok = WorkflowStore.force_reload()
  end
end
