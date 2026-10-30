defmodule Aiur.Executor.HookSettingsFile do
  @moduledoc false
  alias Aiur.Fs
  @marker "AIUR_EXECUTOR_HOOK=1"

  @spec install(Path.t(), map(), String.t()) :: :ok | {:error, term()}
  def install(root, additions, primary_command) do
    update(
      root,
      fn settings ->
        hooks = Map.get(settings, "hooks", %{})

        merged =
          Enum.reduce(additions, hooks, fn {event, entries}, acc ->
            existing = Map.get(acc, event, [])
            # Compare commands individually so later extensions can add entries to an installed event.
            commands = for group <- existing, hook <- group["hooks"], do: hook["command"]
            marked? = Enum.any?(existing, fn group -> Enum.any?(group["hooks"], &owned?/1) end)

            missing =
              Enum.reject(entries, fn group ->
                Enum.all?(group["hooks"], fn hook -> hook["command"] in commands or (marked? and hook["command"] == primary_command) end)
              end)

            Map.put(acc, event, existing ++ missing)
          end)

        Map.put(settings, "hooks", merged)
      end,
      true
    )
  end

  @spec uninstall(Path.t()) :: :ok | {:error, term()}
  def uninstall(root) do
    update(
      root,
      fn settings ->
        if Map.has_key?(settings, "hooks") do
          hooks = for {event, groups} <- settings["hooks"], remaining = remove_owned(groups), remaining != [], into: %{}, do: {event, remaining}
          if hooks == %{}, do: Map.delete(settings, "hooks"), else: Map.put(settings, "hooks", hooks)
        else
          settings
        end
      end,
      false
    )
  end

  defp remove_owned(groups) do
    Enum.flat_map(groups, fn group ->
      remaining = Enum.reject(group["hooks"], &owned?/1)
      if remaining == [], do: [], else: [Map.put(group, "hooks", remaining)]
    end)
  end

  defp owned?(%{"command" => command}) when is_binary(command), do: String.starts_with?(command, @marker)
  defp owned?(_hook), do: false

  defp update(root, transform, backup?) do
    path = Path.join([root, ".claude", "settings.local.json"])

    :global.trans({{__MODULE__, path}, self()}, fn ->
      with {:ok, original, settings} <- read(path),
           updated = transform.(settings) do
        if updated == settings do
          :ok
        else
          with :ok <- File.mkdir_p(Path.dirname(path)),
               :ok <- backup(path, original, backup?) do
            Fs.atomic_write(path, Jason.encode!(updated, pretty: true) <> "\n", mode: 0o600, fsync: true)
          end
        end
      end
    end)
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
    Enum.all?(hooks, fn {_event, groups} ->
      is_list(groups) and
        Enum.all?(groups, fn group ->
          is_map(group) and is_list(group["hooks"]) and Enum.all?(group["hooks"], &is_map/1)
        end)
    end)
  end

  defp valid_hooks?(_hooks), do: false
  defp backup(_path, nil, _backup?), do: :ok
  defp backup(_path, _original, false), do: :ok
  defp backup(path, original, true), do: Fs.atomic_write(path <> ".aiur-bak-#{System.system_time(:nanosecond)}", original, mode: 0o600, fsync: true)
end
