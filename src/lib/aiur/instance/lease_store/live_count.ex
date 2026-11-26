defmodule Aiur.Instance.LeaseStore.LiveCount do
  @moduledoc false

  @key {__MODULE__, :last_known}
  @file_name "last-live-instance-count"

  @spec read() :: pos_integer()
  def read do
    case :persistent_term.get(@key, nil) do
      count when is_integer(count) and count > 0 ->
        count

      _unknown ->
        count = read_file(default_path())
        :persistent_term.put(@key, count)
        count
    end
  end

  @spec remember(pos_integer()) :: pos_integer()
  def remember(count) when is_integer(count) and count > 0 do
    previous = :persistent_term.get(@key, nil)
    :persistent_term.put(@key, count)
    if previous != count, do: write_file(default_path(), count)
    count
  end

  @doc false
  @spec read_file(Path.t()) :: pos_integer()
  def read_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Integer.parse(String.trim(content)) do
          {count, ""} when count > 0 -> count
          _invalid -> 2
        end

      _unavailable ->
        2
    end
  end

  @doc false
  @spec write_file(Path.t(), pos_integer()) :: :ok
  def write_file(path, count) when is_binary(path) and is_integer(count) and count > 0 do
    if ensure_parent(path) == :ok do
      temp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

      with :ok <- File.write(temp, Integer.to_string(count), [:binary]),
           :ok <- File.chmod(temp, 0o600),
           :ok <- File.rename(temp, path) do
        :ok
      else
        _unavailable ->
          _ = File.rm(temp)
          :error
      end
    end

    :ok
  end

  defp default_path, do: Path.join([System.user_home!(), ".aiur", "instances", @file_name])

  defp ensure_parent(path) do
    File.mkdir_p(Path.dirname(path))
  rescue
    _error -> {:error, :unavailable}
  end
end
