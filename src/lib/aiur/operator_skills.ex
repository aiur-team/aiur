defmodule Aiur.OperatorSkills do
  @moduledoc """
  Installs Aiur's operator skills into the local Claude and Codex skill roots.

  Release assembly copies the canonical skill directories alongside the OTP
  release. Symlink installs therefore follow the installed Aiur release, while
  copy installs are deliberately pinned snapshots.
  """

  @type mode :: :symlink | :copy
  @type harness :: :claude | :codex

  @harnesses %{
    claude: %{directory: ".claude/skills", executable: "claude"},
    codex: %{directory: ".codex/skills", executable: "codex"}
  }

  # Keep generic names visibly owned by Aiur in a user's global skill catalog.
  @skills %{
    "aiur-agent" => "aiur-agent",
    "aiur-build" => "aiur-build",
    "aiur-debug" => "aiur-debug",
    "aiur-monitor" => "aiur-monitor",
    "aiur-run" => "aiur-run",
    "design-import" => "aiur-design-import",
    "using-aiur" => "aiur-using-aiur"
  }

  @doc "The operator skills and their collision-safe global names."
  @spec skills() :: %{String.t() => String.t()}
  def skills, do: @skills

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

  @doc "Installs operator skills for `harnesses` without replacing existing paths."
  @spec install(mode(), [harness()], keyword()) :: {:ok, %{created: [Path.t()], existing: [Path.t()]}} | {:conflict, [Path.t()]} | {:error, term()}
  def install(mode, harnesses, opts \\ []) when mode in [:symlink, :copy] do
    source_root = Keyword.get(opts, :source_root, release_skills_root())
    home = Keyword.get(opts, :home, System.user_home!())
    replace_links? = Keyword.get(opts, :replace_links?, false)

    with :ok <- validate_source(source_root),
         destinations = destinations(home, harnesses),
         {:ok, plan, existing} <- preflight(destinations, source_root, mode, replace_links?) do
      apply_plan(plan, mode, existing)
    end
  end

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
      %{destination: Path.join([home, directory, installed_name]), source: source_name}
    end
  end

  defp preflight(destinations, source_root, mode, replace_links?) do
    {plan, existing, conflicts} =
      Enum.reduce(destinations, {[], [], []}, fn %{destination: destination, source: source}, {plan, existing, conflicts} ->
        source = Path.join(source_root, source)

        case destination_status(destination, source, mode, replace_links?) do
          :create -> {[{destination, source, :create} | plan], existing, conflicts}
          :replace_link -> {[{destination, source, :replace_link} | plan], existing, conflicts}
          :existing -> {plan, [destination | existing], conflicts}
          :conflict -> {plan, existing, [destination | conflicts]}
        end
      end)

    if conflicts == [], do: {:ok, Enum.reverse(plan), Enum.reverse(existing)}, else: {:conflict, Enum.reverse(conflicts)}
  end

  defp destination_status(destination, source, :symlink, replace_links?) do
    case File.read_link(destination) do
      {:ok, target} ->
        if Path.expand(target, Path.dirname(destination)) == Path.expand(source) do
          :existing
        else
          if replace_links?, do: :replace_link, else: :conflict
        end

      {:error, :einval} ->
        if File.exists?(destination), do: :conflict, else: :create

      {:error, :enoent} ->
        :create

      {:error, _reason} ->
        :conflict
    end
  end

  defp destination_status(destination, _source, :copy, _replace_links?) do
    if File.exists?(destination) or match?({:ok, _}, File.lstat(destination)), do: :existing, else: :create
  end

  defp apply_plan(plan, mode, existing) do
    Enum.reduce_while(plan, {:ok, %{created: [], existing: []}}, fn {destination, source, action}, {:ok, result} ->
      case install_one(destination, source, action, mode) do
        :ok -> {:cont, {:ok, %{result | created: [destination | result.created]}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, result} -> {:ok, %{result | created: Enum.reverse(result.created), existing: existing}}
      other -> other
    end)
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
      case File.cp_r(source, temporary) do
        {:ok, _copied} ->
          case File.rename(temporary, destination) do
            :ok -> :ok
            {:error, reason} -> {:error, {reason, destination}}
          end

        {:error, reason, _path} ->
          {:error, {reason, destination}}
      end
    after
      File.rm_rf(temporary)
    end
  end
end
