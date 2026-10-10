defmodule Aiur.TestCleanup do
  @moduledoc false

  @retries 40
  @retry_ms 50

  @doc """
  Removes a per-test directory that an app-level writer was pointed at.

  The alert ledger, event-id counter, CI approval store and log handler belong
  to the running application, not to the test, and follow `:aiur` application
  env. A cleanup that removes the directory while an env key still names it
  races every one of them: a write that lands mid-removal makes the final
  `rmdir` fail with ENOTEMPTY, which Elixir renders as "file already exists"
  (#3985). So this refuses to run until every env key is pointed elsewhere —
  restore them first — and then waits out a write already in flight, raising
  if the directory still cannot be removed.

  `on_exit` callbacks run last-registered-first, so call
  `Aiur.TestSupport.put_runtime_state_dir!/1` *after* registering the `on_exit`
  that calls this; its restore then runs before the removal.
  """
  @spec rm_rf!(Path.t()) :: :ok
  def rm_rf!(path) when is_binary(path) do
    case for {key, value} <- Application.get_all_env(:aiur), inside?(value, path), do: key do
      [] -> remove!(path, @retries)
      keys -> raise "cannot remove #{path}: :aiur env #{inspect(Enum.sort(keys))} still points into it; restore before cleanup"
    end
  end

  defp inside?(value, path) when is_binary(value), do: value == path or String.starts_with?(value, path <> "/")
  defp inside?(_value, _path), do: false

  defp remove!(path, retries) do
    case File.rm_rf(path) do
      {:ok, _removed} ->
        :ok

      {:error, reason, file} when retries == 0 ->
        raise "cannot remove #{path}: #{inspect(reason)} at #{file} after #{@retries} attempts; a writer is still active"

      {:error, _reason, _file} ->
        Process.sleep(@retry_ms)
        remove!(path, retries - 1)
    end
  end
end
