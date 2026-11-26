defmodule Aiur.RunTelemetry.SummariesLogsRootTest do
  use ExUnit.Case, async: false

  alias Aiur.RunTelemetry.Summaries

  setup do
    root = Aiur.TestSupport.tmp_root!("summaries-logs-root")
    prior = for key <- [:repo_base_root, :analytics_repo, :log_file], do: {key, Application.fetch_env(:aiur, key)}
    enabled_key = {Aiur.RunTelemetry, :telemetry_enabled}
    enabled = :persistent_term.get(enabled_key, :unset)
    :persistent_term.put(enabled_key, true)
    Application.put_env(:aiur, :repo_base_root, Path.join(root, "state"))
    Application.put_env(:aiur, :analytics_repo, "test/ledger")
    logs_root = Path.join(root, "retained-launches")
    Application.put_env(:aiur, :log_file, Path.join(logs_root, "current/log/aiur.log"))

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, old} -> Application.put_env(:aiur, key, old)
          :error -> Application.delete_env(:aiur, key)
        end
      end

      if enabled == :unset, do: :persistent_term.erase(enabled_key), else: :persistent_term.put(enabled_key, enabled)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root, logs_root: logs_root}
  end

  test "discovers sibling launches beneath the configured log root", %{logs_root: logs_root} do
    files = for launch <- ["prior", "current"], do: Path.join(logs_root, "#{launch}/log/telemetry.ndjson")

    for file <- files do
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "")
    end

    assert {:ok, {_script, args}} = Summaries.reduce_command(reduce_dir: reducer())
    glob = args |> Enum.drop_while(&(&1 != "--telemetry-glob")) |> Enum.at(1)
    assert glob == Path.join(logs_root, "*/log/telemetry.ndjson*")
    assert Enum.sort(Path.wildcard(glob)) == Enum.sort(files)
    assert args |> Enum.drop_while(&(&1 != "--telemetry")) |> Enum.at(1) == List.last(files)
  end

  # Existing override behavior guards the default-root fix against a future regression.
  test "preserves an explicit discovery root override", %{root: root} do
    override = Path.join(root, "override")
    assert {:ok, {_script, args}} = Summaries.reduce_command(reduce_dir: reducer(), logs_root: override)
    assert args |> Enum.drop_while(&(&1 != "--telemetry-glob")) |> Enum.at(1) == Path.join(override, "*/log/telemetry.ndjson*")
  end

  test "limits noncanonical telemetry paths to their own directory", %{root: root} do
    file = Path.join(root, "standalone/telemetry.ndjson")
    assert {:ok, {_script, args}} = Summaries.reduce_command(reduce_dir: reducer(), telemetry_file: file)
    assert args |> Enum.drop_while(&(&1 != "--telemetry-glob")) |> Enum.at(1) == Path.join(root, "standalone/*/log/telemetry.ndjson*")
  end

  test "a CLI logs root excludes unrelated deeper telemetry files", %{root: root} do
    current = Path.join(root, "cli-launch/log/telemetry.ndjson")
    prior = Path.join(root, "prior-launch/log/telemetry.ndjson")
    unrelated = Path.join(root, "other-project/nested/log/telemetry.ndjson")
    Application.put_env(:aiur, :log_file, Path.join(root, "cli-launch/log/aiur.log"))

    for file <- [current, prior, unrelated] do
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "")
    end

    assert {:ok, {_script, args}} = Summaries.reduce_command(reduce_dir: reducer())
    glob = args |> Enum.drop_while(&(&1 != "--telemetry-glob")) |> Enum.at(1)
    assert Enum.sort(Path.wildcard(glob)) == Enum.sort([current, prior])
    refute unrelated in Path.wildcard(glob)
    assert args |> Enum.drop_while(&(&1 != "--telemetry")) |> Enum.at(1) == current
  end

  defp reducer, do: Path.expand("../../../../analytics", __DIR__)
end
