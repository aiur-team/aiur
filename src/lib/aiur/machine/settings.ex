defmodule Aiur.Machine.Settings do
  @moduledoc """
  Machine-wide mobile settings stored separately from workflow configuration.

  `load/0` always reads the file. `get/0` returns the same tagged result, cached
  by path and file identity. If a later read fails, it returns the last good
  settings with `last_error` set to the failure reason. Deletion resets defaults.
  `write/1` merges a partial map into the existing file, preserving future sections.
  """
  alias Aiur.Machine.Settings.{Schema, Validation}
  alias Aiur.Machine.Yaml, as: MachineYaml

  defstruct mobile: %Schema.Mobile{},
            gateway: %Schema.Gateway{},
            pairing: %Schema.Pairing{},
            transport: %Schema.Transport{},
            last_error: nil

  @type t :: %__MODULE__{}
  @type error :: {:invalid, [{String.t(), String.t()}]} | {:unreadable, term()}

  @spec path() :: Path.t()
  def path, do: Application.get_env(:aiur, :machine_settings_path, Path.join([System.get_env("HOME") || Path.expand("~"), ".aiur", "machine"]))

  @spec load() :: {:ok, t()} | {:error, error()}
  def load do
    with {:ok, attrs} <- read(), do: validate(attrs)
  end

  @spec get() :: {:ok, t()} | {:error, error()}
  def get do
    key = {__MODULE__, path()}
    identity = identity()

    case :persistent_term.get(key, nil) do
      {^identity, result} -> result
      cached -> refresh(key, identity, cached)
    end
  end

  defp refresh(key, identity, cached) do
    result = fallback(load(), cached)
    :persistent_term.put(key, {identity, result})
    result
  end

  defp fallback({:error, reason}, {_, {:ok, settings}}), do: {:ok, %{settings | last_error: reason}}
  defp fallback(result, _cached), do: result

  defp identity do
    case File.stat(path(), time: :posix) do
      {:ok, stat} -> {stat.mtime, stat.size, stat.inode}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write(map()) :: :ok | {:error, term()}
  def write(attrs) when is_map(attrs) do
    with {:ok, existing} <- read(),
         merged = merge(existing, stringify(attrs)),
         {:ok, _settings} <- validate(merged),
         :ok <- ensure_directory() do
      Aiur.Fs.atomic_write(path(), MachineYaml.emit(merged), mode: 0o600)
    end
  end

  defp ensure_directory do
    directory = Path.dirname(path())

    case File.mkdir(directory) do
      :ok -> File.chmod(directory, 0o700)
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp read do
    case File.stat(path()) do
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, {:unreadable, reason}}
      {:ok, _stat} -> read_yaml()
    end
  end

  defp read_yaml do
    case Aiur.Yaml.read_from_file(path()) do
      {:ok, nil} -> {:ok, %{}}
      {:ok, attrs} when is_map(attrs) -> {:ok, attrs}
      {:ok, _other} -> {:error, {:invalid, [{"", "must be a mapping"}]}}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp validate(attrs) do
    changeset = Schema.changeset(%Schema{}, Map.take(attrs, ["mobile", "gateway", "pairing", "transport"]))
    errors = Validation.unknown_keys(attrs, Schema) ++ Validation.errors(changeset)

    if errors == [] do
      schema = Ecto.Changeset.apply_changes(changeset)
      {:ok, struct!(__MODULE__, Map.from_struct(schema))}
    else
      {:error, {:invalid, Enum.sort(errors)}}
    end
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp merge(left, right) do
    Map.merge(left, right, fn _key, old, new ->
      if is_map(old) and is_map(new), do: merge(old, new), else: new
    end)
  end
end
