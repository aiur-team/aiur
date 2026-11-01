defmodule Aiur.Toolchain.Probe do
  @moduledoc """
  Reads one CLI a worker spawns (#7443): the path it resolves to on the PATH
  workers inherit, its `--version`, how it was installed, and the newest
  version npm publishes.

  Install kinds:

    * `:npm` — a managed global install; the resolved file lives under `node_modules`.
    * `:dev_link` — an `npm link` or a checkout on PATH; the resolved file sits
      in a package outside `node_modules`. Never replaced automatically.
    * `:standalone` — any other binary (a native installer, Homebrew).
    * `:missing` — not on PATH.
  """

  alias Aiur.Init.ClaudeAdapter

  @version_timeout_ms 15_000
  @npm_timeout_ms 60_000
  @install_timeout_ms 300_000

  @type status :: :missing | :unknown | :below_minimum | :behind | :current | :latest_unknown | :updating
  @type result :: %{
          required(:name) => String.t(),
          required(:package) => String.t(),
          required(:backends) => [String.t()],
          required(:minimum) => String.t() | nil,
          required(:path) => String.t() | nil,
          required(:version) => String.t() | nil,
          required(:kind) => :npm | :dev_link | :standalone | :missing,
          required(:latest) => String.t() | nil,
          required(:status) => status(),
          optional(atom()) => term()
        }

  @doc """
  Probes `tool`. Options: `:path` (PATH string), `:runner` (`System.cmd/3`
  shape) and `:latest` (package name -> version or nil).
  """
  @spec run(map(), keyword()) :: result()
  def run(tool, opts \\ []) do
    path_env = Keyword.get_lazy(opts, :path, fn -> System.get_env("PATH", "") end)
    runner = Keyword.get(opts, :runner, &System.cmd/3)
    latest = Keyword.get(opts, :latest, &npm_latest/1)

    case find_executable(tool[:exe], path_env) do
      nil ->
        Map.merge(tool, %{path: nil, version: nil, kind: :missing, latest: nil})

      path ->
        Map.merge(tool, %{path: path, version: version(path, runner), kind: install_kind(path), latest: latest.(tool.package)})
    end
    |> classify()
  end

  @spec classify(map()) :: result()
  def classify(%{kind: :missing} = tool), do: Map.put(tool, :status, :missing)
  def classify(%{version: nil} = tool), do: Map.put(tool, :status, :unknown)

  def classify(tool) do
    status =
      cond do
        older?(tool.version, tool.minimum) -> :below_minimum
        is_nil(tool.latest) -> :latest_unknown
        older?(tool.version, tool.latest) -> :behind
        true -> :current
      end

    Map.put(tool, :status, status)
  end

  @doc "True when `version` parses and is strictly older than `floor`."
  @spec older?(String.t() | nil, String.t() | nil) :: boolean()
  def older?(version, floor) when is_binary(version) and is_binary(floor) do
    with {:ok, version} <- Version.parse(version),
         {:ok, floor} <- Version.parse(floor),
         do: Version.compare(version, floor) == :lt,
         else: (_unparseable -> false)
  end

  def older?(_version, _floor), do: false

  @spec find_executable(String.t() | nil, String.t()) :: String.t() | nil
  def find_executable(nil, _path_env), do: nil

  def find_executable(exe, path_env) do
    if String.contains?(exe, "/") do
      if executable?(exe), do: Path.expand(exe)
    else
      path_env
      |> String.split(":", trim: true)
      |> Enum.map(&Path.join(&1, exe))
      |> Enum.find(&executable?/1)
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  @spec install_kind(String.t()) :: :npm | :dev_link | :standalone
  def install_kind(path) do
    real = realpath(path)

    cond do
      real |> Path.split() |> Enum.member?("node_modules") -> :npm
      package_ancestor?(Path.dirname(real)) -> :dev_link
      true -> :standalone
    end
  end

  defp package_ancestor?(dir) do
    File.exists?(Path.join(dir, "package.json")) or (Path.dirname(dir) != dir and package_ancestor?(Path.dirname(dir)))
  end

  @doc "Resolves every symlink in `path`, like realpath(3)."
  @spec realpath(String.t()) :: String.t()
  def realpath(path), do: realpath(Path.split(Path.expand(path)), "/", 0)

  defp realpath([], resolved, _hops), do: resolved
  defp realpath(rest, resolved, hops) when hops > 40, do: Path.join([resolved | rest])

  defp realpath([part | rest], resolved, hops) do
    next = Path.join(resolved, part)

    case File.read_link(next) do
      {:ok, target} -> realpath(Path.split(Path.expand(target, resolved)) ++ rest, "/", hops + 1)
      {:error, _not_a_link} -> realpath(rest, next, hops)
    end
  end

  defp version(path, runner) do
    case ClaudeAdapter.bounded_command(fn -> runner.(path, ["--version"], stderr_to_stdout: true) end, @version_timeout_ms) do
      {output, 0} when is_binary(output) -> parse_version(output)
      _failed -> nil
    end
  end

  defp parse_version(output) do
    case Regex.run(~r/\d+\.\d+\.\d+(?:-[0-9A-Za-z.\-]+)?/, output) do
      [version] -> version
      nil -> nil
    end
  end

  @doc "The newest version npm publishes for `package`, or nil when npm cannot say."
  @spec npm_latest(String.t()) :: String.t() | nil
  def npm_latest(package) do
    case npm(["view", package, "version"], @npm_timeout_ms) do
      {:ok, output} -> parse_version(output)
      {:error, _reason} -> nil
    end
  end

  @doc "Installs `package@version` globally with npm."
  @spec npm_install(String.t(), String.t()) :: :ok | {:error, String.t()}
  def npm_install(package, version) do
    with {:ok, _output} <- npm(["install", "-g", "#{package}@#{version}"], @install_timeout_ms), do: :ok
  end

  defp npm(args, timeout_ms) do
    case System.find_executable("npm") do
      nil ->
        {:error, "npm not found on PATH"}

      npm ->
        ClaudeAdapter.bounded_command(fn -> System.cmd(npm, args, stderr_to_stdout: true) end, timeout_ms) |> npm_result()
    end
  end

  defp npm_result({output, 0}), do: {:ok, output}
  defp npm_result({output, status}) when is_binary(output), do: {:error, "npm exited #{status}: #{String.trim(output)}"}
  defp npm_result({:error, reason}), do: {:error, "npm failed: #{inspect(reason)}"}
end
