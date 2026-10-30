defmodule Aiur.Executor.HookSettingsFile do
  @moduledoc false
  alias Aiur.Executor.{HookMerge, HookSettingsBackup}
  alias Aiur.Fs

  @spec install(Path.t(), map()) :: :ok | {:error, term()}
  def install(root, additions) do
    update(root, &HookMerge.merge(&1, :install, additions), true)
  end

  @spec uninstall(Path.t()) :: :ok | {:error, term()}
  def uninstall(root), do: update(root, &HookMerge.merge(&1, :uninstall, %{}), false)

  defp update(root, transform, backup?) do
    path = Path.join([root, ".claude", "settings.local.json"])

    :global.trans({{__MODULE__, path}, self()}, fn ->
      with :ok <- HookSettingsBackup.migrate(root),
           {:ok, original, settings} <- read(path),
           {:ok, updated} <- transform.(settings) do
        write_changed(path, original, settings, updated, backup?)
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
