Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.OptionMediaTest do
  # Open-games #469 and #512 (2026-11-15): workers raised creator Commands with
  # five mode-screen looks as text only, so the creator could not judge them,
  # though the project prompt asked for media on every option.
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.AgentTools.Errors

  @image %{"kind" => "image", "mime_type" => "image/png", "locator" => "https://raw.githubusercontent.com/aiur-team/aiur/main/a.png", "alt_text" => "Ruby wood"}

  setup do
    previous = Application.get_env(:aiur, :workflow_file_path)
    dir = Aiur.TestSupport.tmp_root!("option-media")
    File.mkdir_p!(dir)
    path = Path.join(dir, "config")
    File.write!(path, "tracker: {kind: memory}\n")
    Aiur.Workflow.set_workflow_file_path(path)

    on_exit(fn ->
      if is_nil(previous), do: Aiur.Workflow.clear_workflow_file_path(), else: Aiur.Workflow.set_workflow_file_path(previous)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{config_path: path}
  end

  defp payload(options), do: %{question: "Which mode-screen look?", blocking: true, source_id: "looks", options: options}

  defp text_only, do: [%{id: "ruby", label: "Ruby wood", media: [@image]}, %{id: "jelly", label: "Jelly capsules"}, %{id: "slate", label: "Slate"}]

  defp require_media!(path) do
    File.write!(path, "tracker: {kind: memory}\ndecisions: {require_option_media: true}\n")
    assert :ok = Aiur.WorkflowStore.force_reload()
  end

  test "with the flag on, a Command with a text-only option is refused and names the options", %{dir: dir, config_path: path} do
    require_media!(path)
    pid = start_store!(dir)

    assert {:error, {:decision_invalid, {:option_media_missing, ["jelly", "slate"]}} = reason} = request(pid, payload(text_only()))
    assert DecisionStore.list(pid) == []

    %{"error" => %{"message" => message}} = Errors.payload({:decision_rejected, reason})
    assert message =~ "requires media (an image path or URL) on every option"
    assert message =~ "jelly, slate"

    with_media = Enum.map(text_only(), &Map.put(&1, :media, [@image]))
    assert {:ok, %{status: :accepted}} = request(pid, payload(with_media))
    GenServer.stop(pid)
  end

  test "with the flag on, native and attention Commands are exempt", %{dir: dir, config_path: path} do
    require_media!(path)
    pid = start_store!(dir)

    for origin <- [:native_question, :attention] do
      raw = %{payload(text_only()) | source_id: "#{origin}", question: "#{origin} question"}
      assert {:ok, %{status: :accepted}} = request(pid, raw, origin: origin)
    end

    GenServer.stop(pid)
  end

  test "by default a text-only Command is accepted", %{dir: dir} do
    pid = start_store!(dir)
    assert {:ok, %{status: :accepted}} = request(pid, payload(text_only()))
    GenServer.stop(pid)
  end
end
