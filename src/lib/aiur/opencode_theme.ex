defmodule Aiur.OpencodeTheme do
  @moduledoc """
  Activates a small opencode theme override that dims the
  `markdownBlockQuote` color in chat panes — without forking
  opencode.

  Opencode 1.15.x loads themes from `~/.config/opencode/themes/*.json`
  and from any `.opencode/themes/*.json` found by walking up from
  `cwd`. The active theme key lives in `~/.local/state/opencode/kv.json`
  under `"theme"` and defaults to `"opencode"` when unset.

  This module:

    1. Copies the bundled theme JSON (`priv/opencode_themes/aiur.json`)
       into the configured themes directory so opencode can discover it.
    2. Merges `theme: "aiur"` into kv.json — but **only** when the user
       has not chosen a custom theme. We treat `nil`, missing kv.json,
       `"opencode"` (the built-in default), and `"aiur"` (already us) as
       safe to set. Any other value is preserved as-is so a user-selected
       theme like `"dracula"` is never silently overridden.

  Activation is idempotent — repeated calls with no user-state change
  produce byte-identical kv.json.
  """

  @theme_name "aiur"
  @bundled_theme_filename "aiur.json"

  @doc """
  Ensure the aiur theme is installed and active.

  Returns `{:ok, :active}` only when the bundled theme file is present
  and opencode's active theme state is `aiur` (including when both were
  already true). Returns `{:ok, :custom_theme_preserved}` when the theme
  file is present but the user's custom active theme was left untouched.
  Returns `{:skipped, failures}` for optional setup that could not be
  verified or written; callers should keep booting and print a truthful
  skip message rather than a success line.
  """
  @type status :: :active | :custom_theme_preserved
  @type failure ::
          {:themes_dir, Path.t(), term()}
          | {:theme_copy, Path.t(), term()}
          | {:kv_read, Path.t(), term()}
          | {:kv_dir, Path.t(), term()}
          | {:kv_write, Path.t(), term()}

  @spec ensure_active(keyword()) :: {:ok, status()} | {:skipped, [failure()]}
  def ensure_active(opts \\ []) do
    themes_dir = Keyword.get(opts, :themes_dir, default_themes_dir())
    kv_path = Keyword.get(opts, :kv_path, default_kv_path())

    theme_result = install_theme_file(themes_dir)
    kv_result = maybe_set_active_theme(kv_path)
    failures = failures(theme_result) ++ failures(kv_result)

    cond do
      failures != [] -> {:skipped, failures}
      kv_result == :custom_theme_preserved -> {:ok, :custom_theme_preserved}
      true -> {:ok, :active}
    end
  end

  defp install_theme_file(themes_dir) do
    dest = Path.join(themes_dir, @bundled_theme_filename)
    source = bundled_theme_path()

    case mkdir_themes_dir(themes_dir) do
      :ok -> copy_or_verify_theme(source, dest)
      error -> error
    end
  end

  defp mkdir_themes_dir(themes_dir) do
    case File.mkdir_p(themes_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, [{:themes_dir, themes_dir, reason}]}
    end
  end

  defp copy_or_verify_theme(source, dest) do
    case File.copy(source, dest) do
      {:ok, _} -> :ok
      {:error, reason} -> verify_existing_theme(source, dest, reason)
    end
  end

  defp verify_existing_theme(source, dest, reason) do
    with {:ok, source_body} <- File.read(source),
         {:ok, dest_body} <- File.read(dest),
         true <- source_body == dest_body do
      :ok
    else
      _ -> {:error, [{:theme_copy, dest, reason}]}
    end
  end

  defp maybe_set_active_theme(kv_path) do
    {decision_input, current_kv} = read_kv(kv_path)

    case theme_action(decision_input) do
      :set -> write_kv(kv_path, merge_theme(current_kv))
      :active -> :active
      :preserve_custom -> :custom_theme_preserved
      {:error, reason} -> {:error, [{:kv_read, kv_path, reason}]}
    end
  end

  defp read_kv(kv_path) do
    case File.read(kv_path) do
      {:ok, body} -> decode_kv(body)
      {:error, :enoent} -> {:enoent, %{}}
      {:error, reason} -> {{:read_error, reason}, %{}}
    end
  end

  defp decode_kv(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {decoded, decoded}
      _ -> {:enoent, %{}}
    end
  end

  defp write_kv(kv_path, new_kv) do
    parent = Path.dirname(kv_path)

    with :ok <- mkdir_kv_dir(parent),
         :ok <- write_kv_file(kv_path, new_kv) do
      :active
    end
  end

  defp mkdir_kv_dir(parent) do
    case File.mkdir_p(parent) do
      :ok -> :ok
      {:error, reason} -> {:error, [{:kv_dir, parent, reason}]}
    end
  end

  defp write_kv_file(kv_path, new_kv) do
    encoded = Jason.encode!(new_kv, pretty: true)

    case File.write(kv_path, encoded) do
      :ok -> :ok
      {:error, reason} -> {:error, [{:kv_write, kv_path, reason}]}
    end
  end

  defp failures(:ok), do: []
  defp failures(:active), do: []
  defp failures(:custom_theme_preserved), do: []
  defp failures({:error, failures}), do: failures

  @doc """
  Decide whether `kv.json`'s `theme` key should be (re)set to `aiur`.

    * `:enoent` — kv.json missing entirely → safe to set
    * map without `theme` key → opencode falls back to its default → safe to set
    * map with `theme: "opencode"` → the built-in default → safe to set (this
      is what fresh installs show)
    * map with `theme: "aiur"` → already us → idempotent set is fine
    * any other string → user chose a custom theme → leave alone
  """
  @spec should_set_theme?(map() | :enoent) :: boolean()
  def should_set_theme?(:enoent), do: true

  def should_set_theme?(kv) when is_map(kv) do
    theme_action(kv) in [:set, :active]
  end

  defp theme_action(:enoent), do: :set
  defp theme_action({:read_error, reason}), do: {:error, reason}

  defp theme_action(kv) when is_map(kv) do
    case Map.get(kv, "theme") do
      nil -> :set
      "opencode" -> :set
      @theme_name -> :active
      other when is_binary(other) -> :preserve_custom
      _ -> :set
    end
  end

  @doc """
  Return a new kv map with `theme: "aiur"` set. All other keys are
  preserved untouched.
  """
  @spec merge_theme(map()) :: map()
  def merge_theme(kv) when is_map(kv) do
    Map.put(kv, "theme", @theme_name)
  end

  defp default_themes_dir do
    config = System.get_env("XDG_CONFIG_HOME") || Path.expand("~/.config")
    Path.join([config, "opencode", "themes"])
  end

  defp default_kv_path do
    state = System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state")
    Path.join([state, "opencode", "kv.json"])
  end

  defp bundled_theme_path do
    Application.app_dir(:aiur, ["priv", "opencode_themes", @bundled_theme_filename])
  end
end
