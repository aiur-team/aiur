defmodule Aiur.Orchestrator.TransitionFacadeGuardTest do
  use ExUnit.Case, async: true

  @facades ~w(terminate_running_issue resume_paused_issue reactivate_issue transition_control_status preserve_running_issue_on_external_error pause_issue_for_ci_wait maybe_deactivate_human_review_issue)a
  @root Path.expand("../../..", __DIR__)

  test "orchestration submodules never call or capture a transition facade" do
    files = Path.wildcard(Path.join(@root, "lib/aiur/orchestrator/**/*.ex"))
    assert length(files) > 100

    violations =
      for file <- files,
          call <- facade_calls(File.read!(file)),
          do: {Path.relative_to(file, @root), call}

    assert violations == []
  end

  # Future regression guard: the sanctioned build-queue caller keeps U2's label-writer seam.
  test "future regression guard: build queue produces no effects and calls no Orchestrator facade" do
    files = Path.wildcard(Path.join(@root, "lib/aiur/build_queue/**/*.ex"))
    assert files != []

    violations =
      for file <- files,
          source = File.read!(file),
          Regex.match?(~r/\b(?:Aiur\.)?Orchestrator\b(?!\.TicketTransition\b)|\b(?:apply_effect|apply_effects|Effect)\b/, source),
          do: file

    assert violations == []
  end

  defp facade_calls(source) do
    ast = Code.string_to_quoted!(source)

    {_, aliases} =
      Macro.prewalk(ast, MapSet.new([:Orchestrator]), fn
        {:alias, _, [{:__aliases__, _, [:Aiur, :Orchestrator]}, opts]} = node, acc ->
          {:__aliases__, _, [name]} = Keyword.fetch!(opts, :as)
          {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    {_, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, module}, function]}, _, _} = node, calls when function in @facades ->
          if module == [:Aiur, :Orchestrator] or (length(module) == 1 and MapSet.member?(aliases, hd(module))), do: {node, [function | calls]}, else: {node, calls}

        node, calls ->
          {node, calls}
      end)

    calls
  end
end
