defmodule Aiur.SupervisionHealth.Tree do
  @moduledoc false

  @spec expected(Supervisor.supervisor(), [term()]) :: map()
  def expected(supervisor, ids) do
    children = children_by_id(supervisor)
    nested = Map.new(ids, &{&1, nested_tree(children, &1)})
    %{ids: ids, nested: nested}
  end

  @spec check(Supervisor.supervisor(), map(), [term()], map()) :: {non_neg_integer(), [map()]}
  def check(supervisor, %{ids: expected_ids, nested: nested}, path, last_terminations) do
    children = children_by_id(supervisor)

    Enum.reduce(expected_ids, {0, []}, fn id, acc ->
      check_child(acc, Map.get(children, id), nested[id], id, path, last_terminations)
    end)
  end

  @spec child_id(Supervisor.child_spec()) :: term()
  def child_id(spec), do: spec |> Supervisor.child_spec([]) |> Map.fetch!(:id)

  @spec monitored(Supervisor.supervisor(), map(), [term()]) :: [map()]
  def monitored(supervisor, %{ids: ids, nested: nested}, path) do
    children = children_by_id(supervisor)
    Enum.flat_map(ids, &monitored_child(Map.get(children, &1), nested[&1], path, &1))
  end

  defp nested_tree(children, id) do
    case Map.get(children, id) do
      {^id, pid, :supervisor, _modules} when is_pid(pid) -> expected(pid, static_child_ids(pid))
      _child -> nil
    end
  end

  defp children_by_id(supervisor), do: supervisor |> Supervisor.which_children() |> Map.new(&{elem(&1, 0), &1})

  defp check_child({expected, missing}, {id, pid, :supervisor, _modules}, tree, id, path, last_terminations) when is_pid(pid) do
    check_supervisor({expected, missing}, pid, tree, id, path, last_terminations)
  end

  defp check_child({expected, missing}, {id, pid, _type, _modules}, _tree, id, _path, _last_terminations) when is_pid(pid),
    do: {expected + 1, missing}

  defp check_child({expected, missing}, _child, tree, id, path, last_terminations) do
    child_path = path ++ [id]
    down = %{id: id, path: child_path, reason: Map.get(last_terminations, child_path) || Map.get(last_terminations, id)}
    descendants = missing_descendants(tree, child_path)
    {expected + 1 + length(descendants), [down | descendants ++ missing]}
  end

  defp check_supervisor({expected, missing}, _pid, nil, _id, _path, _last_terminations), do: {expected + 1, missing}

  defp check_supervisor({expected, missing}, pid, tree, id, path, last_terminations) do
    {nested_expected, nested_missing} = check(pid, tree, path ++ [id], last_terminations)
    {expected + 1 + nested_expected, missing ++ nested_missing}
  end

  defp missing_descendants(nil, _path), do: []

  defp missing_descendants(%{ids: ids, nested: nested}, path) do
    Enum.flat_map(ids, fn id ->
      down = %{id: id, path: path ++ [id], reason: nil}
      [down | missing_descendants(nested[id], path ++ [id])]
    end)
  end

  defp static_child_ids(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&(&1 == :undefined))
  end

  defp monitored_child({id, pid, type, _modules}, tree, path, id) when is_pid(pid) do
    child = %{path: path ++ [id], pid: pid, type: type}
    [child | monitored_descendants(child, tree)]
  end

  defp monitored_child(_child, _tree, _path, _id), do: []

  defp monitored_descendants(%{pid: pid, type: :supervisor, path: path}, tree) when not is_nil(tree),
    do: monitored(pid, tree, path)

  defp monitored_descendants(_child, _tree), do: []
end
