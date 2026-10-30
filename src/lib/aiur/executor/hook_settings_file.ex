defmodule Aiur.Executor.HookSettingsFile do
  @moduledoc false
  alias Aiur.Executor.HookSettingsBackup
  alias Aiur.Fs
  @marker "AIUR_EXECUTOR_HOOK=1"

  @spec install(Path.t(), map(), String.t()) :: :ok | {:error, term()}
  def install(root, additions, primary_command) do
    update(root, &merge_settings(&1, additions, primary_command), true)
  end

  defp merge_settings(settings, additions, primary_command) do
    hooks = Map.get(settings, "hooks", %{})

    merged =
      Enum.reduce(additions, hooks, fn {event, entries}, acc ->
        Map.put(acc, event, append_missing(Map.get(acc, event, []), entries, primary_command))
      end)

    Map.put(settings, "hooks", merged)
  end

  defp append_missing(existing, entries, primary_command) do
    # Compare commands individually so later extensions can add entries to an installed event.
    commands = for group <- existing, hook <- group["hooks"], do: hook["command"]
    marked? = Enum.any?(commands, &(is_binary(&1) and String.starts_with?(&1, @marker)))

    missing =
      Enum.reject(entries, fn group ->
        Enum.all?(group["hooks"], fn hook -> hook["command"] in commands or (marked? and hook["command"] == primary_command) end)
      end)

    existing ++ missing
  end

  @spec uninstall(Path.t()) :: :ok | {:error, term()}
  def uninstall(root), do: update(root, &remove_settings/1, false)

  defp remove_settings(%{"hooks" => hooks} = settings) do
    remaining = for {event, groups} <- hooks, kept = remove_owned(groups), kept != [], into: %{}, do: {event, kept}
    if remaining == %{}, do: Map.delete(settings, "hooks"), else: Map.put(settings, "hooks", remaining)
  end

  defp remove_settings(settings), do: settings

  defp remove_owned(groups) do
    Enum.flat_map(groups, fn group ->
      remaining = Enum.reject(group["hooks"], &owned?/1)
      if remaining == [] and group["hooks"] != [], do: [], else: [Map.put(group, "hooks", remaining)]
    end)
  end

  defp owned?(%{"command" => command}) when is_binary(command), do: String.starts_with?(command, @marker)
  defp owned?(_hook), do: false

  defp update(root, transform, backup?) do
    path = Path.join([root, ".claude", "settings.local.json"])

    :global.trans({{__MODULE__, path}, self()}, fn ->
      with :ok <- HookSettingsBackup.migrate(root),
           {:ok, original, settings} <- read(path) do
        write_changed(path, original, settings, transform.(settings), backup?)
      end
    end)
  end

  defp write_changed(_path, _original, settings, settings, _backup?), do: :ok

  defp write_changed(path, original, _settings, updated, backup?) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- backup(path, original, backup?),
         {:ok, contents} <- updated_contents(updated, backup?) do
      Fs.atomic_write(path, contents, mode: 0o600, fsync: true)
    end
  end

  defp updated_contents(updated, true), do: {:ok, Jason.encode!(updated, pretty: true) <> "\n"}

  defp updated_contents(updated, false) do
    with {:ok, restored} <- HookSettingsBackup.restore_bytes(updated) do
      {:ok, restored || Jason.encode!(updated, pretty: true) <> "\n"}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:error, :enoent} -> {:ok, nil, %{}}
      {:error, reason} -> {:error, reason}
      {:ok, original} -> decode(original)
    end
  end

  defp decode(original) do
    with {:ok, settings} when is_map(settings) <- Jason.decode(original),
         true <- valid_hooks?(Map.get(settings, "hooks", %{})) do
      {:ok, original, settings}
    else
      _ -> {:error, :unparsable}
    end
  end

  defp valid_hooks?(hooks) when is_map(hooks) do
    Enum.all?(hooks, fn {_event, groups} -> is_list(groups) and Enum.all?(groups, &valid_group?/1) end)
  end

  defp valid_hooks?(_hooks), do: false
  defp valid_group?(group), do: is_map(group) and is_list(group["hooks"]) and Enum.all?(group["hooks"], &is_map/1)
  defp backup(_path, nil, _backup?), do: :ok
  defp backup(_path, _original, false), do: :ok
  defp backup(path, original, true), do: HookSettingsBackup.create(path, original)
end
