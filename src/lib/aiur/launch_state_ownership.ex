defmodule Aiur.LaunchStateOwnership do
  @moduledoc """
  Verifies legacy launch ownership using the launcher's `log/aiur.crash`.

  `record_beam_crash` writes the release node and absolute launch root in a
  fixed header. Config paths, repo basenames, PIDs and workspace roots cannot
  prove instance ownership: they can be shared or reused. A missing record
  deliberately means no adoption, including for clean legacy shutdowns.
  """

  @header "aiur background BEAM exited unexpectedly\n"
  @detector "detected_by: background BEAM-death watchdog (no clean stop sentinel)"
  @launch_dir_pattern ~r/\A\d{8}T\d{6}Z-\d+\z/

  @doc "Returns true only when all recorded crash headers identify this instance and launch."
  @spec owned?(Path.t()) :: boolean()
  def owned?(log_dir) do
    with key when is_binary(key) and key != "" <- System.get_env("AIUR_INSTANCE_KEY"),
         node when is_binary(node) <- System.get_env("AIUR_RELEASE_NODE"),
         true <- String.ends_with?(node, "-#{key}@127.0.0.1"),
         true <- Path.basename(log_dir) == "log",
         true <- Regex.match?(@launch_dir_pattern, Path.basename(Path.dirname(log_dir))),
         {:ok, contents} <- File.read(Path.join(log_dir, "aiur.crash")),
         ["" | [_ | _] = records] <- String.split(contents, @header) do
      Enum.all?(records, &matching_record?(&1, node, Path.dirname(Path.expand(log_dir))))
    else
      _ -> false
    end
  end

  defp matching_record?(record, node, launch_dir) do
    case String.split(record, "\n", parts: 5) do
      ["timestamp: " <> timestamp, "node: " <> recorded_node, "run_log_dir: " <> recorded_dir, @detector | _] ->
        match?({:ok, _, _}, DateTime.from_iso8601(timestamp)) and
          recorded_node == node and recorded_dir == launch_dir

      _ ->
        false
    end
  end
end
