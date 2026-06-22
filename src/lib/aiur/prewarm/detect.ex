defmodule Aiur.Prewarm.Detect do
  @moduledoc """
  Repo-agnostic toolchain detection for the warm-base build command.

  Walks a repo tree for a known manifest (Elixir/Node/Go/Rust/Python), resolves
  the build **root** (the manifest's directory — NOT the repo root: aiur's own
  `mix.exs` lives in `src/` behind a lockfile-less root `package.json`), and
  synthesizes a one-time install+compile command routed through `mise exec --`
  so it pins the same runtime on Linux and macOS.

  Returns `{:ok, %{language:, build_root:, command:}}` or `:none` when nothing
  is detected or detection is ambiguous (multiple languages with no
  lockfile-tiebreaker, or a monorepo orchestrator like nx/turbo). `:none` is the
  signal to fall back to the agent-prompt path — never a guess.
  """

  @type result :: {:ok, %{language: atom(), build_root: String.t(), command: String.t()}} | :none

  # Manifest filename(s) that identify each supported language.
  @manifests [
    {:elixir, ["mix.exs"]},
    {:node, ["package.json"]},
    {:go, ["go.mod"]},
    {:rust, ["Cargo.toml"]},
    {:python, ["pyproject.toml", "requirements.txt"]}
  ]

  # Lockfiles whose presence distinguishes a real project from a vanity/shim
  # manifest (the tiebreaker when several languages are present).
  @lockfiles %{
    elixir: ["mix.lock"],
    node: ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock"],
    go: ["go.sum"],
    rust: ["Cargo.lock"],
    python: ["poetry.lock", "uv.lock", "pdm.lock", "Pipfile.lock"]
  }

  # Directories never worth descending into when hunting for a manifest.
  @skip_dirs ~w(.git node_modules deps _build target vendor cover .elixir_ls priv)
  @max_depth 4

  @doc "Detect the warm-base build command for the repo rooted at `root`."
  @spec detect(Path.t()) :: result()
  def detect(root \\ ".") do
    root
    |> find_manifests()
    |> shallowest_per_language()
    |> select()
    |> case do
      nil -> :none
      {lang, dir} -> resolve(lang, dir, root)
    end
  end

  # ---- manifest discovery ----

  defp find_manifests(root), do: walk(root, 0, [])

  defp walk(_dir, depth, acc) when depth > @max_depth, do: acc

  defp walk(dir, depth, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        acc = collect_manifests(dir, depth, acc)

        entries
        |> Enum.filter(&(&1 not in @skip_dirs and File.dir?(Path.join(dir, &1))))
        |> Enum.reduce(acc, fn sub, a -> walk(Path.join(dir, sub), depth + 1, a) end)

      _ ->
        acc
    end
  end

  defp collect_manifests(dir, depth, acc) do
    Enum.reduce(@manifests, acc, fn {lang, files}, a ->
      if Enum.any?(files, &File.regular?(Path.join(dir, &1))) do
        [{lang, dir, depth} | a]
      else
        a
      end
    end)
  end

  defp shallowest_per_language(manifests) do
    manifests
    |> Enum.group_by(fn {lang, _dir, _depth} -> lang end)
    |> Enum.map(fn {_lang, list} -> Enum.min_by(list, fn {_l, _d, depth} -> depth end) end)
  end

  # ---- selection ----

  defp select([]), do: nil
  defp select([{lang, dir, _depth}]), do: {lang, dir}

  defp select(candidates) do
    # Multiple languages: the lockfile is the tiebreaker. Exactly one
    # lockfile-backed candidate wins (this is how aiur's real `src/mix.exs`
    # beats its lockfile-less root `package.json`); anything else is ambiguous.
    case Enum.filter(candidates, fn {lang, dir, _} -> has_lock?(lang, dir) end) do
      [{lang, dir, _}] -> {lang, dir}
      _ -> nil
    end
  end

  defp has_lock?(lang, dir) do
    @lockfiles |> Map.get(lang, []) |> Enum.any?(&File.regular?(Path.join(dir, &1)))
  end

  # ---- command synthesis ----

  defp resolve(lang, dir, root) do
    if node_orchestrator?(lang, dir) do
      :none
    else
      rel = relative_root(dir, root)
      {:ok, %{language: lang, build_root: rel, command: prefix(rel) <> command_for(lang, dir)}}
    end
  end

  # nx/turbo monorepos have orchestrator-specific build graphs a generic
  # `<pm> run build` would get wrong -> defer to the agent-prompt fallback.
  defp node_orchestrator?(:node, dir) do
    File.regular?(Path.join(dir, "nx.json")) or File.regular?(Path.join(dir, "turbo.json"))
  end

  defp node_orchestrator?(_lang, _dir), do: false

  defp relative_root(dir, root) do
    case Path.relative_to(dir, root) do
      ^dir -> "."
      "" -> "."
      rel -> rel
    end
  end

  defp prefix("."), do: ""
  defp prefix(rel), do: "cd #{rel} && "

  defp command_for(:elixir, _dir) do
    "mise exec -- mix local.hex --force --if-missing && " <>
      "mise exec -- mix local.rebar --force --if-missing && " <>
      "mise exec -- mix deps.get && mise exec -- mix compile"
  end

  defp command_for(:node, dir) do
    install = node_install(dir)

    case node_build(dir) do
      nil -> install
      build -> install <> " && " <> build
    end
  end

  defp command_for(:go, _dir), do: "mise exec -- go mod download && mise exec -- go build ./..."
  defp command_for(:rust, _dir), do: "mise exec -- cargo build"
  defp command_for(:python, dir), do: python_install(dir)

  defp node_install(dir) do
    cond do
      File.regular?(Path.join(dir, "pnpm-lock.yaml")) ->
        "mise exec -- corepack enable && mise exec -- pnpm install --frozen-lockfile"

      File.regular?(Path.join(dir, "bun.lockb")) or File.regular?(Path.join(dir, "bun.lock")) ->
        "mise exec -- bun install"

      File.regular?(Path.join(dir, "yarn.lock")) ->
        "mise exec -- corepack enable && mise exec -- yarn install --immutable"

      File.regular?(Path.join(dir, "package-lock.json")) ->
        "mise exec -- npm ci"

      true ->
        "mise exec -- npm install"
    end
  end

  # Append a build step only when package.json actually declares a `build` script.
  defp node_build(dir) do
    with {:ok, raw} <- File.read(Path.join(dir, "package.json")),
         {:ok, %{"scripts" => %{"build" => _}}} <- Jason.decode(raw) do
      pm = node_run_pm(dir)
      "mise exec -- #{pm} run build"
    else
      _ -> nil
    end
  end

  defp node_run_pm(dir) do
    cond do
      File.regular?(Path.join(dir, "pnpm-lock.yaml")) -> "pnpm"
      File.regular?(Path.join(dir, "yarn.lock")) -> "yarn"
      File.regular?(Path.join(dir, "bun.lockb")) or File.regular?(Path.join(dir, "bun.lock")) -> "bun"
      true -> "npm"
    end
  end

  defp python_install(dir) do
    cond do
      File.regular?(Path.join(dir, "poetry.lock")) -> "mise exec -- poetry install"
      File.regular?(Path.join(dir, "uv.lock")) -> "mise exec -- uv sync"
      File.regular?(Path.join(dir, "pdm.lock")) -> "mise exec -- pdm install"
      File.regular?(Path.join(dir, "Pipfile.lock")) -> "mise exec -- pipenv install"
      File.regular?(Path.join(dir, "requirements.txt")) -> "mise exec -- pip install -r requirements.txt"
      true -> "mise exec -- pip install -e ."
    end
  end
end
