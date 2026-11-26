defmodule Aiur.TestSupport.WorkflowFiles do
  require Logger

  alias Aiur.TestSupport.{RuntimeChildren, WorkflowYaml}

  @workflow_reload_timeout_ms 15_000

  @doc """
  Writes a workflow fixture and waits for the active `WorkflowStore` cache to
  reload before returning.

  Files other than the active workflow path are staging fixtures and do not
  trigger a reload.
  """
  def write_workflow_file!(path, overrides \\ []) do
    write_workflow_content!(path, overrides)

    if active_workflow_file?(path) do
      RuntimeChildren.ensure_workflow_store_running()
      :ok = Aiur.WorkflowStore.force_reload(@workflow_reload_timeout_ms)
    end

    :ok
  end

  @doc """
  Writes a workflow fixture and makes a best-effort attempt to reload the
  active `WorkflowStore` cache.

  The reload call can block until the store responds or its configured timeout
  elapses. Use this only when the test deliberately exercises asynchronous
  reload behavior: reload failures are logged and swallowed, so callers have
  no cache-visibility guarantee.
  """
  def write_workflow_file_async!(path, overrides \\ []) do
    write_workflow_content!(path, overrides)

    if active_workflow_file?(path) and is_pid(Process.whereis(Aiur.WorkflowStore)) do
      try do
        case Aiur.WorkflowStore.force_reload(async_workflow_reload_timeout_ms()) do
          :ok -> :ok
          {:error, reason} -> log_async_reload_failure(path, reason)
        end
      catch
        :exit, reason -> log_async_reload_failure(path, reason)
      end
    end

    :ok
  end

  @doc """
  Writes raw YAML to a workflow fixture atomically (temp file + rename) and
  does not reload the store.

  Use for intentionally-invalid fixture content, which must land as a single
  unit: a plain `File.write!/2` truncates before writing, so the
  `WorkflowStore` background poll can read the empty intermediate — empty YAML
  parses successfully — and commit those defaults as last-known-good before the
  test's own `force_reload/1` runs (#1635).
  """
  @spec write_workflow_file_atomic!(Path.t(), String.t()) :: :ok
  def write_workflow_file_atomic!(path, content) when is_binary(content) do
    atomic_write!(path, content)
  end

  defp write_workflow_content!(path, overrides) do
    {config_yaml, prompt} = WorkflowYaml.workflow_content(overrides)

    config_yaml =
      if is_binary(prompt) and prompt != "" do
        prompt_basename = String.trim_leading(Path.basename(path), ".") <> ".prompt.md"
        File.write!(Path.join(Path.dirname(path), prompt_basename), prompt <> "\n")
        config_yaml <> "prompt_file: #{prompt_basename}\n"
      else
        config_yaml
      end

    atomic_write!(path, config_yaml)
    write_default_alerts_file!(path)
  end

  # `File.write!/2` truncates before writing, so a `WorkflowStore` poll (or an
  # unrelated restart) can observe an empty intermediate file and commit it as
  # a valid last-known-good workflow (empty YAML parses successfully). Write to
  # a sibling temp file and rename so the active config only ever exists as a
  # complete unit (#1635).
  defp atomic_write!(path, content) do
    tmp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp"
      )

    File.write!(tmp, content)
    File.rename!(tmp, path)
    :ok
  end

  defp active_workflow_file?(path) do
    Path.expand(path) == Path.expand(Aiur.Workflow.workflow_file_path())
  end

  defp async_workflow_reload_timeout_ms do
    Application.get_env(:aiur, :workflow_store_call_timeout_ms, 5_000)
  end

  defp log_async_reload_failure(path, reason) do
    Logger.warning("Best-effort workflow reload failed path=#{path} reason=#{inspect(reason)}; WorkflowStore may serve stale test config")
  end

  # Mirror the real `.aiur/` layout in tests: drop the canonical alert
  # definitions next to the generated config so `Alerts` resolves its default
  # `<config-dir>/alerts` the same way a real run does. Tests that need
  # different (or no) definitions still override via `:alerts_file_path` or an
  # `alerts_file` config entry — both take precedence over this default.
  @default_alerts_source Path.expand("../../../../.aiur/alerts", __DIR__)

  @doc "Absolute path of the repository's canonical `.aiur/alerts` definitions, or nil."
  @spec default_alerts_source() :: String.t() | nil
  def default_alerts_source, do: @default_alerts_source

  defp write_default_alerts_file!(config_path) do
    dest = Path.join(Path.dirname(config_path), "alerts")
    if File.regular?(@default_alerts_source), do: File.cp!(@default_alerts_source, dest)
  end
end
