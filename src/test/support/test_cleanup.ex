defmodule Aiur.TestCleanup do
  @moduledoc false

  @retries 40
  @retry_ms 50
  # Short: a live writer is back within a millisecond or two, and every cleanup pays this.
  @settle_ms 5

  @doc """
  Removes a per-test directory that an app-level writer was pointed at.

  The alert ledger, event-id counter, CI approval store and log handler belong
  to the running application, not to the test, and follow `:aiur` application
  env. A cleanup that removes the directory while an env key still names it
  races every one of them: a write that lands mid-removal makes the final
  `rmdir` fail with ENOTEMPTY, which Elixir renders as "file already exists"
  (#3985). So this refuses to run until every env key is pointed elsewhere —
  restore them first — and then waits out a write already in flight. A writer
  that never stops fails the cleanup with the files it kept putting back, even
  when one removal attempt happened to win the race.

  `on_exit` callbacks run last-registered-first, so call
  `Aiur.TestSupport.put_runtime_state_dir!/1` *after* registering the `on_exit`
  that calls this; its restore then runs before the removal. Where a restore
  registered earlier cannot be reordered, `unset: [key]` deletes those keys
  first; the later restore still puts the previous value back. `rm:` replaces
  `File.rm_rf/1` so this module's own test can stage a lost race on demand.
  """
  @spec rm_rf!(Path.t(), unset: [atom()], rm: (Path.t() -> {:ok, [binary()]} | {:error, File.posix(), binary()})) :: :ok
  def rm_rf!(path, opts \\ []) when is_binary(path) do
    Enum.each(Keyword.get(opts, :unset, []), &Application.delete_env(:aiur, &1))

    case for {key, value} <- Application.get_all_env(:aiur), inside?(value, path), do: key do
      [] -> remove!(path, Keyword.get(opts, :rm, &File.rm_rf/1), @retries)
      keys -> raise "cannot remove #{path}: :aiur env #{inspect(Enum.sort(keys))} still points into it; restore before cleanup"
    end
  end

  defp inside?(value, path) when is_binary(value), do: value == path or String.starts_with?(value, path <> "/")
  defp inside?(_value, _path), do: false

  defp remove!(path, rm, retries) do
    case rm.(path) do
      {:ok, _removed} ->
        Process.sleep(@settle_ms)
        if File.exists?(path), do: retry!(path, rm, retries, "it reappeared after removal"), else: :ok

      # ENOTEMPTY (rendered :eexist) is the only failure a write in flight causes.
      {:error, reason, file} when reason in [:eexist, :enotempty] ->
        Process.sleep(@retry_ms)
        retry!(path, rm, retries, "#{inspect(reason)} at #{file}")

      {:error, reason, file} ->
        raise "cannot remove #{path}: #{inspect(reason)} at #{file}"
    end
  end

  defp retry!(path, _rm, 0, why) do
    # An undeletable file surfaces as the same ENOTEMPTY a live writer causes, so name both.
    left = path |> Path.join("**") |> Path.wildcard(match_dot: true) |> Enum.reject(&File.dir?/1)

    raise "cannot remove #{path}: #{why} after #{@retries} attempts; files still present " <>
            "(a live writer keeps putting them back, or they cannot be deleted): #{inspect(left)}"
  end

  defp retry!(path, rm, retries, _why), do: remove!(path, rm, retries - 1)
end
