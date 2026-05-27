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

  require Logger

  @theme_name "aiur"
  @bundled_theme_filename "aiur.json"

  @doc """
  Ensure the aiur theme is installed and active. Returns `:ok` even
  when individual side-effects (file copy, kv.json write) fail — those
  are surfaced via Logger so a misconfigured opencode install never
  blocks aiur from booting. Pass `:themes_dir` and `:kv_path` to
  redirect for testing.
  """
  @spec ensure_active(keyword()) :: :ok
  def ensure_active(opts \\ []) do
    themes_dir = Keyword.get(opts, :themes_dir, default_themes_dir())
    kv_path = Keyword.get(opts, :kv_path, default_kv_path())

    install_theme_file(themes_dir)
    maybe_set_active_theme(kv_path)

    :ok
  end

  defp install_theme_file(themes_dir) do
    case File.mkdir_p(themes_dir) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("opencode_theme themes_dir mkdir failed dir=#{themes_dir} reason=#{inspect(reason)}")
        :ok
    end

    dest = Path.join(themes_dir, @bundled_theme_filename)
    source = bundled_theme_path()

    case File.copy(source, dest) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("opencode_theme copy failed src=#{source} dest=#{dest} reason=#{inspect(reason)}")
        :ok
    end
  end

  defp maybe_set_active_theme(kv_path) do
    {decision_input, current_kv} =
      case File.read(kv_path) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, decoded} when is_map(decoded) -> {decoded, decoded}
            _ -> {:enoent, %{}}
          end

        {:error, :enoent} ->
          {:enoent, %{}}

        {:error, reason} ->
          Logger.warning("opencode_theme kv.json read failed path=#{kv_path} reason=#{inspect(reason)}")
          {:enoent, %{}}
      end

    if should_set_theme?(decision_input) do
      write_kv(kv_path, merge_theme(current_kv))
    end
  end

  defp write_kv(kv_path, new_kv) do
    parent = Path.dirname(kv_path)

    case File.mkdir_p(parent) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("opencode_theme kv dir mkdir failed dir=#{parent} reason=#{inspect(reason)}")
    end

    encoded = Jason.encode!(new_kv, pretty: true)

    case File.write(kv_path, encoded) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("opencode_theme kv.json write failed path=#{kv_path} reason=#{inspect(reason)}")
        :ok
    end
  end

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
    case Map.get(kv, "theme") do
      nil -> true
      "opencode" -> true
      @theme_name -> true
      other when is_binary(other) -> false
      _ -> true
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
