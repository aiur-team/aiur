defmodule Aiur.Init.ClaudeAdapter do
  @moduledoc false

  alias Aiur.{CodingAgent, Config}

  @min_version "1.1.0"
  @release_fallback "github:aiur-team/aiur-claude#v#{@min_version}"
  @command_timeout_ms 60_000

  @spec install(String.t()) :: :ok | {:error, String.t()}
  def install(package_spec) do
    case run_npm(["install", "-g", package_spec]) do
      {:ok, _output} -> :ok
      {:error, _message} = error -> error
    end
  end

  @spec registry_version() :: {:ok, String.t()} | {:error, String.t()}
  def registry_version do
    case run_npm(["view", "aiur-claude", "version"]) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, _message} = error -> error
    end
  end

  @spec install_spec({:ok, String.t()} | {:error, String.t()}) :: String.t()
  def install_spec(result) do
    case classify(result) do
      {:satisfying, version} -> "aiur-claude@#{version}"
      _ -> @release_fallback
    end
  end

  @spec classify(:missing | {:ok, String.t()} | {:error, String.t()}) ::
          :missing | {:satisfying, String.t()} | {:outdated, String.t()} | {:unknown, String.t()}
  def classify(:missing), do: :missing

  def classify({:ok, version}) do
    case Version.parse(version) do
      {:ok, parsed} ->
        if Version.compare(parsed, @min_version) == :lt,
          do: {:outdated, version},
          else: {:satisfying, version}

      :error ->
        {:unknown, "unparseable version: #{version}"}
    end
  end

  def classify({:error, reason}), do: {:unknown, reason}

  @spec min_version() :: String.t()
  def min_version, do: @min_version

  @spec version() :: :missing | {:ok, String.t()} | {:error, String.t()}
  def version do
    command = Config.backend_config("claude")["command"] || get_in(CodingAgent.backends(), ["claude", :default_command])
    version(command, &System.find_executable/1, &System.cmd/3)
  end

  @doc false
  @spec version(String.t() | nil, (String.t() -> String.t() | nil), (String.t(), [String.t()], keyword() -> {String.t(), integer()})) ::
          :missing | {:ok, String.t()} | {:error, String.t()}
  def version(command, find_executable, command_runner) do
    with [exe | configured_args] <- command_parts(command),
         path when is_binary(path) <- find_executable.(exe) do
      case command_runner.(path, configured_args ++ ["--version"], stderr_to_stdout: true) do
        {output, 0} -> parse_version(output)
        {output, status} -> {:error, "#{exe} --version exited #{status}: #{String.trim(output)}"}
      end
    else
      _ -> :missing
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc false
  @spec bounded_command((-> term()), non_neg_integer()) :: term() | {:error, :timeout | term()}
  def bounded_command(fun, timeout_ms) when is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms >= 0 do
    parent = self()
    result_ref = make_ref()
    {pid, monitor_ref} = spawn_monitor(fn -> send(parent, {result_ref, fun.()}) end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, reason}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor_ref, [:flush])
        {:error, :timeout}
    end
  end

  @spec command_parts(String.t() | nil) :: [String.t()]
  def command_parts(command) when is_binary(command), do: String.split(String.trim(command), ~r/\s+/, trim: true)
  def command_parts(_command), do: []

  defp run_npm(args) do
    with npm when is_binary(npm) <- System.find_executable("npm") || {:error, "npm not found on PATH"} do
      case bounded_command(fn -> System.cmd(npm, args, stderr_to_stdout: true) end, @command_timeout_ms) do
        {:error, :timeout} -> {:error, "npm timed out after #{@command_timeout_ms}ms"}
        {:error, reason} -> {:error, "npm failed: #{inspect(reason)}"}
        {output, 0} -> {:ok, output}
        {output, status} -> {:error, "npm exited #{status}: #{String.trim(output)}"}
      end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp parse_version(output) do
    case Regex.run(~r/\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?/, output) do
      [version] -> {:ok, version}
      _ -> {:error, "unreadable --version output: #{String.trim(output)}"}
    end
  end
end
