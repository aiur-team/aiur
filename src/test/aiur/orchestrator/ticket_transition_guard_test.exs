defmodule Aiur.Orchestrator.TicketTransitionGuardTest do
  use ExUnit.Case, async: false
  alias Mix.Tasks.Xref

  @writers [Aiur.Tracker, Aiur.GitHub.Tracker, Aiur.GitHub.Client, Aiur.GitHub.IssueState, Aiur.Memory.Tracker, Aiur.Linear.Tracker]
  @write_functions [:update_issue_state, :add_label, :remove_label, :swap_labels, :do_update_issue_state]
  @allowed [Aiur.Orchestrator.TicketTransition | @writers]
  # Dev-only sandbox reset deliberately uses gh rather than the production owner.
  @allowed_paths ["lib/aiur/test_reset.ex"]

  test "compiled lifecycle writes belong only to the transition owner and adapters" do
    # Xref inspection is deprecated, but provides the compiled, alias-resolved calls this guard needs.
    calls = apply(Xref, :calls, [])
    assert Enum.any?(calls, &(&1.callee == {Aiur.Tracker, :update_issue_state, 3})), "xref must collect real compiled calls"

    violations =
      Enum.filter(calls, fn %{callee: {module, function, _}, caller_module: caller, file: file} ->
        module in @writers and function in @write_functions and caller not in @allowed and file not in @allowed_paths
      end)

    assert violations == [], "Lifecycle write bypasses TicketTransition: #{inspect(violations)}"
  end

  test "dynamic tracker dispatch cannot bypass the transition owner" do
    violations = for path <- Path.wildcard("lib/**/*.ex"), path not in @allowed_paths, not adapter_path?(path), dynamic_tracker_apply?(File.read!(path)), do: path
    assert violations == [], "Dynamic tracker apply bypasses TicketTransition: #{inspect(violations)}"
  end

  defp adapter_path?(path) do
    path in [
      "lib/aiur/tracker.ex",
      "lib/aiur/github/tracker.ex",
      "lib/aiur/github/client.ex",
      "lib/aiur/github/issue_state.ex",
      "lib/aiur/memory/tracker.ex",
      "lib/aiur/linear/tracker.ex",
      "lib/aiur/orchestrator/ticket_transition.ex"
    ]
  end

  defp dynamic_tracker_apply?(source) do
    ast = Code.string_to_quoted!(source)

    {_, aliases} =
      Macro.prewalk(ast, MapSet.new([:Tracker, :GitHubTracker, :IssueState]), fn
        {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [name]}]]} = node, names ->
          names = if Module.concat(parts) in @writers, do: MapSet.put(names, name), else: names
          {node, names}

        node, names ->
          {node, names}
      end)

    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:apply, _, [{:__aliases__, _, parts} | _]} = node, found ->
          {node, found or tracker_alias?(parts, aliases)}

        {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, [{:__aliases__, _, parts} | _]} = node, found ->
          {node, found or tracker_alias?(parts, aliases)}

        node, found ->
          {node, found}
      end)

    found?
  end

  defp tracker_alias?(parts, aliases), do: Module.concat(parts) in @writers or MapSet.member?(aliases, List.last(parts))
end
