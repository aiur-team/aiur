defmodule Aiur.OperatorSkills do
  @moduledoc """
  Installs Aiur's operator skills into the local Claude and Codex skill roots.

  Release assembly copies the canonical skill directories alongside the OTP
  release. Symlink installs therefore follow the installed Aiur release, while
  copy installs are deliberately pinned snapshots.
  """

  @type mode :: :symlink | :copy
  @type harness :: :claude | :codex

  # Written into every copied skill so a later run can tell an installation it
  # made from an unrelated directory that merely occupies the same path.
  @marker ".aiur-operator-skill"

  @harnesses %{
    claude: %{directory: ".claude/skills", executable: "claude"},
    codex: %{directory: ".codex/skills", executable: "codex"}
  }

  # Keep generic names visibly owned by Aiur in a user's global skill catalog.
  # `aiur-run`'s shipped manual routes the operator to `aiur-meta` and
  # `aiur-intro`, so shipping it without them would ship a broken manual.
  @skills %{
    "aiur-agent" => "aiur-agent",
    "aiur-build" => "aiur-build",
    "aiur-debug" => "aiur-debug",
    "aiur-intro" => "aiur-intro",
    "aiur-meta" => "aiur-meta",
    "aiur-monitor" => "aiur-monitor",
    "aiur-run" => "aiur-run",
    "design-import" => "aiur-design-import",
    "using-aiur" => "aiur-using-aiur"
  }

  @doc "The operator skills and their collision-safe global names."
  @spec skills() :: %{String.t() => String.t()}
  def skills, do: @skills

  @doc "The provenance marker a copy install leaves inside each skill directory."
  @spec marker_filename() :: String.t()
  def marker_filename, do: @marker

  @doc "Harnesses that can accept a global skill installation on this machine."
  @spec detect_harnesses(keyword()) :: [harness()]
  def detect_harnesses(opts \\ []) do
    home = Keyword.get(opts, :home, System.user_home!())
    executable? = Keyword.get(opts, :executable?, &System.find_executable/1)

    @harnesses
    |> Enum.filter(fn {_name, %{directory: directory, executable: executable}} ->
      File.dir?(Path.join(home, directory)) or is_binary(executable?.(executable))
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @typedoc "One skill installed into one harness."
  @type entry :: %{skill: String.t(), installed_name: String.t(), harness: harness(), destination: Path.t()}

  @typedoc """
  What actually happened, per destination.

  `skipped` and `failed` entries carry a `:reason`. Every destination lands in
  exactly one bucket, so a partial install is reported as the partial install it
  is rather than as a flat failure.
  """
  @type report :: %{created: [entry()], existing: [entry()], skipped: [map()], failed: [map()]}

  @doc """
  Installs operator skills for `harnesses` without replacing existing paths.

  The decision is per destination. A destination that is blocked skips only
  itself; the remaining skills still install. `{:error, reason}` is reserved for
  a precondition that makes the whole install meaningless, such as a missing
  source tree.
  """
  @spec install(mode(), [harness()], keyword()) :: {:ok, report()} | {:error, term()}
  def install(mode, harnesses, opts \\ []) when mode in [:symlink, :copy] do
    source_root = Keyword.get(opts, :source_root, release_skills_root())
    home = Keyword.get(opts, :home, System.user_home!())
    replace_links? = Keyword.get(opts, :replace_links?, false)

    with :ok <- validate_source(source_root) do
      home
      |> destinations(harnesses)
      |> Enum.reduce(%{created: [], existing: [], skipped: [], failed: []}, fn entry, report ->
        install_entry(entry, source_root, mode, replace_links?, report)
      end)
      |> then(&{:ok, Map.new(&1, fn {bucket, entries} -> {bucket, Enum.reverse(entries)} end)})
    end
  end

  @doc "The distinct skills named by a list of report entries."
  @spec distinct_skills([map()]) :: [String.t()]
  def distinct_skills(entries), do: entries |> Enum.map(& &1.skill) |> Enum.uniq()

  @doc "The distinct harnesses named by a list of report entries."
  @spec distinct_harnesses([map()]) :: [harness()]
  def distinct_harnesses(entries), do: entries |> Enum.map(& &1.harness) |> Enum.uniq() |> Enum.sort()

  @doc "The release-owned root that symlink installations target."
  @spec release_skills_root() :: Path.t()
  def release_skills_root do
    :aiur
    |> Application.app_dir()
    |> Path.join("../../operator-skills")
    |> Path.expand()
  end

  defp validate_source(source_root) do
    if Enum.all?(Map.keys(@skills), &File.dir?(Path.join(source_root, &1))) do
      :ok
    else
      {:error, {:missing_operator_skills, source_root}}
    end
  end

  defp destinations(home, harnesses) do
    for harness <- harnesses,
        %{directory: directory} = Map.fetch!(@harnesses, harness),
        {source_name, installed_name} <- @skills do
      %{
        skill: source_name,
        installed_name: installed_name,
        harness: harness,
        destination: Path.join([home, directory, installed_name])
      }
    end
  end

  defp install_entry(entry, source_root, mode, replace_links?, report) do
    source = Path.join(source_root, entry.skill)

    case destination_status(entry.destination, source, mode, replace_links?) do
      {:skip, reason} ->
        record(report, :skipped, Map.put(entry, :reason, reason))

      :existing ->
        record(report, :existing, entry)

      action ->
        case install_one(entry.destination, source, action, mode) do
          :ok -> record(report, :created, entry)
          {:error, reason} -> record(report, :failed, Map.put(entry, :reason, reason))
        end
    end
  end

  defp record(report, bucket, entry), do: Map.update!(report, bucket, &[entry | &1])

  defp destination_status(destination, source, :symlink, replace_links?) do
    case File.read_link(destination) do
      {:ok, target} ->
        symlink_status(target, destination, source, replace_links?)

      # Not a symlink. Anything already sitting here belongs to the user, and
      # calling it a link that points elsewhere would be a confident wrong reason.
      {:error, :einval} ->
        if File.exists?(destination), do: {:skip, :occupied}, else: :create

      {:error, :enoent} ->
        :create

      {:error, reason} ->
        {:skip, {:unreadable, reason}}
    end
  end

  # A copy carries no link target to identify it, so provenance has to be
  # written down. Only a directory holding our marker naming this same skill is
  # ours; anything else occupying the path is the operator's and is skipped, not
  # counted as a kept operator skill.
  defp destination_status(destination, source, :copy, _replace_links?) do
    cond do
      installed_copy?(destination, Path.basename(source)) -> :existing
      occupied?(destination) -> {:skip, :occupied}
      true -> :create
    end
  end

  defp installed_copy?(destination, skill) do
    case File.read(Path.join(destination, @marker)) do
      {:ok, contents} -> String.trim(contents) == skill
      {:error, _reason} -> false
    end
  end

  defp occupied?(destination) do
    File.exists?(destination) or match?({:ok, _}, File.lstat(destination))
  end

  defp symlink_status(target, destination, source, replace_links?) do
    cond do
      Path.expand(target, Path.dirname(destination)) == Path.expand(source) -> :existing
      replace_links? -> :replace_link
      true -> {:skip, :link_elsewhere}
    end
  end

  defp install_one(destination, source, :create, :symlink) do
    File.mkdir_p(Path.dirname(destination))

    case File.ln_s(source, destination) do
      :ok -> :ok
      {:error, :eexist} -> {:error, {:destination_exists, destination}}
      {:error, reason} -> {:error, {reason, destination}}
    end
  end

  defp install_one(destination, source, :replace_link, :symlink) do
    with :ok <- File.rm(destination), do: install_one(destination, source, :create, :symlink)
  end

  defp install_one(destination, source, :create, :copy) do
    temporary = destination <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))
    File.mkdir_p(Path.dirname(destination))

    try do
      # The marker goes in before the rename, so a destination never exists
      # without the provenance that later identifies it as ours.
      with {:ok, _copied} <- File.cp_r(source, temporary),
           :ok <- File.write(Path.join(temporary, @marker), Path.basename(source) <> "\n") do
        case File.rename(temporary, destination) do
          :ok -> :ok
          {:error, reason} -> {:error, {reason, destination}}
        end
      else
        {:error, reason, _path} -> {:error, {reason, destination}}
        {:error, reason} -> {:error, {reason, destination}}
      end
    after
      File.rm_rf(temporary)
    end
  end
end
