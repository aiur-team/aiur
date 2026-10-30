defmodule Aiur.Executor.HookMerge do
  @moduledoc false
  @marker "AIUR_EXECUTOR_HOOK=1"

  @spec merge(map(), :install | :uninstall, map()) :: {:ok, map()} | {:error, :invalid_hooks_config}
  def merge(config, action, fragment) when action in [:install, :uninstall] do
    if valid?(config) and valid?(%{"hooks" => fragment}) do
      hooks = Map.get(config, "hooks", %{})
      updated = if action == :install, do: install(hooks, fragment), else: uninstall(hooks, fragment)
      result = if updated == %{}, do: Map.delete(config, "hooks"), else: Map.put(config, "hooks", updated)
      {:ok, result}
    else
      {:error, :invalid_hooks_config}
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(config) when is_map(config) do
    case Map.get(config, "hooks", %{}) do
      hooks when is_map(hooks) -> Enum.all?(hooks, fn {_event, groups} -> is_list(groups) and Enum.all?(groups, &valid_group?/1) end)
      _ -> false
    end
  end

  def valid?(_config), do: false
  defp valid_group?(group), do: is_map(group) and is_list(group["hooks"]) and Enum.all?(group["hooks"], &is_map/1)

  defp install(hooks, fragment) do
    primary = get_in(fragment, ["SessionStart", Access.at(0), "hooks", Access.at(0), "command"])

    Enum.reduce(fragment, hooks, fn {event, additions}, acc ->
      existing = Map.get(acc, event, [])
      Map.put(acc, event, Enum.reduce(additions, existing, &append_missing(&1, &2, primary)))
    end)
  end

  defp append_missing(group, existing, primary) do
    commands = for entry <- existing, hook <- entry["hooks"], do: hook["command"]
    missing = Enum.reject(group["hooks"], &present?(&1["command"], commands, primary))
    if missing == [], do: existing, else: existing ++ [Map.put(group, "hooks", missing)]
  end

  defp present?(command, commands, primary) do
    command in commands or (command == primary and Enum.any?(commands, &ingest?/1))
  end

  defp ingest?(command), do: is_binary(command) and String.starts_with?(command, @marker) and not deliver?(command)

  defp uninstall(hooks, fragment) do
    commands = for {_event, groups} <- fragment, group <- groups, hook <- group["hooks"], do: hook["command"]
    for {event, groups} <- hooks, kept = remove_owned(groups, commands), kept != [], into: %{}, do: {event, kept}
  end

  defp remove_owned(groups, commands) do
    Enum.flat_map(groups, fn group ->
      remaining = Enum.reject(group["hooks"], &owned?(&1, commands))
      if remaining == [] and group["hooks"] != [], do: [], else: [Map.put(group, "hooks", remaining)]
    end)
  end

  defp owned?(%{"command" => command}, commands) when is_binary(command) do
    command in commands or String.starts_with?(command, @marker) or deliver?(command)
  end

  defp owned?(_hook, _commands), do: false

  defp deliver?(command) when is_binary(command) do
    (String.starts_with?(command, @marker) or String.starts_with?(command, "aiur_hook_token=$(cat ") or
       String.starts_with?(command, "curl -sS -f -m 3 ")) and
      String.contains?(command, "curl -sS -f -m 3 ") and String.contains?(command, "/api/v1/executor/hook/deliver?")
  end

  defp deliver?(_command), do: false
end
