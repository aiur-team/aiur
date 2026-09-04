defmodule Aiur.Claude.AdapterHealth do
  @moduledoc """
  Resolves the required `aiur-claude` release and reports adapter capability.

  Registry and version failures are deliberately fail-open. A transport error
  is never treated as evidence that a release is unpublished, and unknown
  runtime state never clears or fires a durable degradation condition.
  """

  require Logger

  alias Aiur.{AlertFeed, Alerts, Issue}
  alias Aiur.Claude.Config, as: ClaudeConfig

  @package "aiur-claude"
  @min_version "1.1.0"
  @github_release_commit "3478281243bfec8b9e1719461ff17c836c07c5b8"
  @npm_spec "#{@package}@#{@min_version}"
  @github_spec "github:aiur-team/aiur-claude##{@github_release_commit}"
  @registry_url "https://registry.npmjs.org/aiur-claude/#{@min_version}"
  @request_timeout_ms 5_000
  @version_timeout_ms 5_000
  @missing_tools "aiur_declare_blocker, emit_alert, aiur_subscribe"

  @type release_status :: :available | :not_found | {:unknown, term()}
  @type version_status :: :capable | {:degraded, String.t()} | :unknown

  @spec min_version() :: String.t()
  def min_version, do: @min_version

  @spec github_release_commit() :: String.t()
  def github_release_commit, do: @github_release_commit

  @spec release_status((String.t(), keyword() -> {:ok, map()} | {:error, term()})) :: release_status()
  def release_status(request_fun \\ &Req.get/2) when is_function(request_fun, 2) do
    request_opts = [
      headers: [accept: "application/json"],
      connect_options: [timeout: @request_timeout_ms],
      receive_timeout: @request_timeout_ms,
      retry: false
    ]

    case request_fun.(@registry_url, request_opts) do
      {:ok, %{status: 200, body: %{"version" => @min_version}}} -> :available
      {:ok, %{status: 200}} -> {:unknown, :unexpected_metadata}
      {:ok, %{status: 404}} -> :not_found
      {:ok, %{status: status}} -> {:unknown, {:unexpected_status, status}}
      {:error, reason} -> {:unknown, reason}
      _other -> {:unknown, :unexpected_response}
    end
  rescue
    _error -> {:unknown, :request_failed}
  end

  @spec install_spec(release_status()) :: String.t()
  def install_spec(:available), do: @npm_spec
  def install_spec(:not_found), do: @github_spec
  def install_spec({:unknown, _reason}), do: @github_spec

  @spec install_command(String.t()) :: String.t()
  def install_command(spec), do: "npm install -g #{spec}"

  # Every operator-facing instruction leads with the uninstall: `npm install -g`
  # over a half-removed global package is the ENOTEMPTY this ticket is about,
  # and an instruction that fails is the defect, not the fix.
  @spec install_instruction(release_status()) :: String.t()
  def install_instruction(release_status) do
    "#{uninstall_command()}, then #{install_command(install_spec(release_status))}"
  end

  @spec uninstall_command() :: String.t()
  def uninstall_command, do: "npm uninstall -g #{@package}"

  @spec package() :: String.t()
  def package, do: @package

  @spec remediation(release_status()) :: String.t()
  def remediation(:available) do
    "upgrade it with: #{install_instruction(:available)}"
  end

  def remediation(:not_found) do
    "the #{@min_version} npm release is pending; upgrade with: #{install_instruction(:not_found)}"
  end

  def remediation({:unknown, _reason} = release_status) do
    "couldn't confirm the npm release; use the reviewed GitHub release: " <>
      "#{install_instruction(release_status)} (exact npm alternative: #{install_command(@npm_spec)})"
  end

  @spec version_status({:ok, String.t()} | {:error, term()}) :: version_status()
  def version_status({:ok, version}) when is_binary(version) do
    case Version.parse(version) do
      {:ok, parsed} ->
        if Version.compare(parsed, @min_version) == :lt,
          do: {:degraded, version},
          else: :capable

      :error ->
        :unknown
    end
  end

  def version_status({:error, _reason}), do: :unknown
  def version_status(_other), do: :unknown

  @spec warning({:ok, String.t()} | {:error, term()}, release_status()) :: :ok | {:error, String.t()}
  def warning(version_result, release_status) do
    case version_status(version_result) do
      :capable ->
        :ok

      {:degraded, version} ->
        {:error,
         "aiur-claude #{version} is older than #{@min_version} — claude agents will run " <>
           "without Aiur coordination tools (#{@missing_tools}). #{remediation(release_status)}"}

      :unknown ->
        {:error,
         "couldn't determine the aiur-claude version — if it's older than #{@min_version}, " <>
           "claude agents will run without Aiur coordination tools (#{@missing_tools}). " <>
           remediation(release_status)}
    end
  end

  @spec installed_version(keyword()) :: {:ok, String.t()} | {:error, atom()}
  def installed_version(opts \\ []) do
    with [executable] <- command_tokens(ClaudeConfig.command()),
         true <- Path.basename(executable) == "aiur-claude",
         path when is_binary(path) <- find_executable(executable, opts) do
      run_version_command(path, opts)
    else
      _other -> {:error, :custom_or_unavailable_command}
    end
  rescue
    _error -> {:error, :version_check_failed}
  end

  @spec report_runtime(Issue.t(), Path.t() | nil, keyword()) :: :ok
  def report_runtime(issue, workspace, opts \\ []) do
    version_fun = Keyword.get(opts, :version_fun, &installed_version/0)
    release_status_fun = Keyword.get(opts, :release_status_fun, &release_status/0)
    condition_state_fun = Keyword.get(opts, :condition_state_fun, &AlertFeed.condition_state/1)
    emit_fun = Keyword.get(opts, :emit_fun, &Alerts.emit_system/2)
    condition = "ticket.#{issue.identifier}.agent.attention.adapter_degraded"

    case version_status(version_fun.()) do
      {:degraded, version} ->
        if condition_state_fun.(condition) != :firing do
          emit_fun.(condition,
            issue: issue,
            workspace: workspace,
            worker_host: nil,
            reason: degraded_reason(version, release_status_fun.()),
            needs_attention: true,
            severity: "warning"
          )
        end

      :capable ->
        if condition_state_fun.(condition) == :firing do
          emit_fun.(condition <> ".resolved",
            issue: issue,
            workspace: workspace,
            worker_host: nil,
            reason: "aiur-claude #{@min_version} or newer is active; Claude coordination tools are available again",
            needs_attention: false,
            severity: "info"
          )
        end

      :unknown ->
        Logger.warning("could not determine aiur-claude adapter health; leaving the durable degradation condition unchanged")
    end

    :ok
  rescue
    _error ->
      Logger.warning("could not report aiur-claude adapter health; continuing the Claude session")
      :ok
  end

  defp degraded_reason(version, release_status) do
    "aiur-claude #{version} is older than #{@min_version}; this Claude session is running without " <>
      "Aiur coordination tools (#{@missing_tools}). #{remediation(release_status)}"
  end

  # ClaudeConfig.command/0 always returns a binary; a surprise value raises and
  # is caught by installed_version/1's rescue.
  defp command_tokens(command), do: String.split(String.trim(command), ~r/\s+/, trim: true)

  defp find_executable(executable, opts) do
    Keyword.get(opts, :find_executable_fun, &System.find_executable/1).(executable)
  end

  defp run_version_command(path, opts) do
    command_fun = Keyword.get(opts, :command_fun, &System.cmd/3)
    timeout = Keyword.get(opts, :timeout, @version_timeout_ms)

    task =
      Task.async(fn ->
        try do
          {:command_result, command_fun.(path, ["--version"], stderr_to_stdout: true)}
        rescue
          _error -> {:error, :version_check_failed}
        catch
          _kind, _reason -> {:error, :version_check_failed}
        end
      end)

    case Task.yield(task, timeout) do
      {:ok, {:command_result, {output, 0}}} -> parse_version(output)
      {:ok, {:command_result, {_output, _status}}} -> {:error, :version_check_failed}
      {:ok, {:error, :version_check_failed}} -> {:error, :version_check_failed}
      {:exit, _reason} -> {:error, :version_check_failed}
      nil -> stop_timed_out_probe(task)
    end
  end

  defp stop_timed_out_probe(task) do
    Task.shutdown(task, :brutal_kill)
    {:error, :version_check_timed_out}
  end

  defp parse_version(output) do
    case Regex.run(~r/\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?/, output) do
      [version] -> {:ok, version}
      _other -> {:error, :unreadable_version}
    end
  end
end
