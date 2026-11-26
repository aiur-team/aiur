defmodule Aiur.Alerts.Sound do
  @moduledoc false

  require Logger

  # Built-in OS system sounds keyed by alert category. macOS ships AIFF clips in
  # the system sounds folder; Linux desktops ship freedesktop OGA themes, with a
  # generic ALSA WAV as a last resort. Missing files are filtered out at play
  # time, so an absent set degrades to silence rather than crashing.
  @macos_sounds_dir "/System/Library/Sounds"
  @freedesktop_sounds_dir "/usr/share/sounds/freedesktop/stereo"
  @alsa_sounds_dir "/usr/share/sounds/alsa"

  @macos_category_sounds %{
    needs_input: "Glass",
    stuck: "Sosumi",
    done: "Hero",
    default: "Tink"
  }

  @freedesktop_category_sounds %{
    needs_input: "message-new-instant",
    stuck: "dialog-warning",
    done: "complete",
    default: "dialog-information"
  }

  @alsa_fallback "Front_Center"

  # Extensions tried when resolving a `<category>` override file inside a
  # configured `sound_dir`, ordered most- to least-preferred.
  @sound_dir_exts ~w(.oga .ogg .wav .aiff .aif .mp3)

  @category_basenames %{needs_input: "needs-input", stuck: "stuck", done: "done", default: "default"}

  # Substring → category, in match order. The first match wins, so more specific
  # markers are listed ahead of broader ones. This drives OS-default-sound
  # selection only; the topic→sound *mapping* in `.aiur/alerts` is the
  # source of truth for the non-OS-default path. Keep new alert topics in sync
  # across both. The `.paused` needle is delimiter-anchored so it does not also
  # match the `agent.unpaused` resume topic.
  @topic_categories [
    {"human-review", :needs_input},
    {"input_required", :needs_input},
    {".paused", :stuck},
    {"draft", :stuck},
    {"thrash", :stuck},
    {"retry_exhausted", :stuck},
    {"tokens_exhausted", :stuck},
    {"pr.merged", :done},
    {"merging", :done},
    {"state.changed", :done}
  ]

  defp config_sounds(%{sound: sounds}), do: sounds
  defp config_sounds(_config), do: []

  # `use_os_default_sounds: false` (default) uses the topic→sound mapping from
  # the alerts file; `true` maps the alert's category to a built-in OS system sound
  # (with a `sound_dir` per-category override).
  @doc false
  @spec select_sound(String.t(), map() | nil, map()) :: String.t() | nil
  def select_sound(topic, _definition, %{use_os_default_sounds: true} = settings) do
    os_default_sound(topic, settings)
  end

  def select_sound(_topic, definition, settings) do
    definition
    |> config_sounds()
    |> pick_mapping_sound(settings.sound_dir)
  end

  defp pick_mapping_sound([], _sound_dir), do: nil
  defp pick_mapping_sound(sounds, sound_dir), do: sounds |> Enum.random() |> resolve_sound_path(sound_dir)

  # A bare filename resolves against `sound_dir`; URLs and explicit `~/`/absolute
  # paths are taken as-is (the latter keeps the existing `~/alerts/*.wav` map
  # working regardless of `sound_dir`).
  defp resolve_sound_path("http://" <> _ = url, _sound_dir), do: url
  defp resolve_sound_path("https://" <> _ = url, _sound_dir), do: url
  defp resolve_sound_path("~/" <> _ = path, _sound_dir), do: expand_path(path)
  defp resolve_sound_path("/" <> _ = path, _sound_dir), do: path

  defp resolve_sound_path(name, sound_dir) when is_binary(sound_dir) and sound_dir != "",
    do: Path.join(expand_path(sound_dir), name)

  defp resolve_sound_path(name, _sound_dir), do: name

  defp os_default_sound(topic, settings) do
    category = categorize_topic(topic)
    sound_dir_override(category, settings.sound_dir) || os_sound_for_category(category)
  end

  # A `<category>.<ext>` file in the configured `sound_dir` wins over the OS
  # default for that category, letting users override individual categories.
  defp sound_dir_override(_category, sound_dir) when not is_binary(sound_dir), do: nil
  defp sound_dir_override(_category, ""), do: nil

  defp sound_dir_override(category, sound_dir) do
    base = expand_path(sound_dir)
    name = Map.fetch!(@category_basenames, category)

    Enum.find_value(@sound_dir_exts, fn ext ->
      path = Path.join(base, name <> ext)
      if File.exists?(path), do: path
    end)
  end

  # Maps an alert topic to a coarse category used to pick an OS-default sound.
  # Public (undocumented) so tests can exercise the mapping for the real
  # stuck/needs-input/done topics deterministically.
  @doc false
  @spec categorize_topic(String.t()) :: :needs_input | :stuck | :done | :default
  def categorize_topic(topic) when is_binary(topic) do
    Enum.find_value(@topic_categories, :default, fn {needle, category} ->
      if String.contains?(topic, needle), do: category
    end)
  end

  def categorize_topic(_topic), do: :default

  defp os_sound_for_category(category) do
    category
    |> os_sound_candidates(os_type())
    |> Enum.find(&File.exists?/1)
  end

  # Ordered absolute candidate paths for a category's OS-default sound, per OS.
  # Public (undocumented) and OS-injectable so platform mapping is tested
  # deterministically regardless of the host running the suite.
  @doc false
  @spec os_sound_candidates(atom(), {atom(), atom()} | term()) :: [String.t()]
  def os_sound_candidates(category, {:unix, :darwin}) do
    [Path.join(@macos_sounds_dir, Map.fetch!(@macos_category_sounds, category) <> ".aiff")]
  end

  def os_sound_candidates(category, {:unix, _}) do
    [
      Path.join(@freedesktop_sounds_dir, Map.fetch!(@freedesktop_category_sounds, category) <> ".oga"),
      Path.join(@alsa_sounds_dir, @alsa_fallback <> ".wav")
    ]
  end

  def os_sound_candidates(_category, _os_type), do: []

  defp os_type, do: :os.type()

  # Non-raising `~/` expansion: sound resolution runs outside `maybe_play_sound`'s
  # rescue, so a missing HOME must degrade to the unexpanded path, never crash a
  # turn.
  @doc false
  @spec expand_path(String.t()) :: String.t()
  def expand_path("~/" <> rest = path) do
    case System.user_home() do
      home when is_binary(home) -> Path.join(home, rest)
      _ -> path
    end
  end

  def expand_path(path), do: path

  # `enabled: false` gates all playback; a nil sound (nothing matched / no OS
  # default present) is a silent no-op.
  @doc false
  @spec maybe_play_sound(String.t() | nil, map(), keyword()) :: :ok
  def maybe_play_sound(_sound, %{enabled: false}, _opts), do: :ok
  def maybe_play_sound(nil, _settings, _opts), do: :ok

  def maybe_play_sound(sound, _settings, opts) do
    if test_env_without_player_override?(opts) do
      :ok
    else
      sound_player(opts).(sound)
      :ok
    end
  rescue
    error ->
      Logger.debug("Alert playback failed for #{inspect(sound)}: #{Exception.message(error)}")
      :ok
  end

  defp test_env_without_player_override?(opts) when is_list(opts) do
    Application.get_env(:aiur, :env) == :test and not Keyword.has_key?(opts, :player)
  end

  defp sound_player(opts) do
    case Keyword.fetch(opts, :player) do
      {:ok, player} -> player
      :error -> Application.get_env(:aiur, :alert_sound_player, &default_player/1)
    end
  end

  # Public (but undocumented) so tests can exercise the URL / missing-
  # binary / missing-file branches without round-tripping through
  # `maybe_play_sound`'s `test_env_without_player_override?/1`
  # short-circuit. The 2-arity form takes an injectable
  # `find_executable_fn` so tests can simulate a system on which a
  # given player is available.
  @doc false
  @spec default_player(String.t()) :: :ok | {:ok, pid()}
  def default_player(sound), do: default_player(sound, &System.find_executable/1)

  @doc false
  @spec default_player(String.t(), (String.t() -> String.t() | nil)) :: :ok | {:ok, pid()}
  def default_player("http://" <> _url, _find_executable_fn), do: :ok
  def default_player("https://" <> _url, _find_executable_fn), do: :ok

  def default_player(sound, find_executable_fn)
      when is_binary(sound) and is_function(find_executable_fn, 1) do
    with {executable, build_args} <- player_command(os_type(), find_executable_fn),
         true <- File.exists?(sound) do
      Task.start(fn -> System.cmd(executable, build_args.(sound), stderr_to_stdout: true) end)
    else
      _ -> :ok
    end
  end

  # Resolves the first available audio player for the given OS to `{executable,
  # build_args}` (where `build_args.(sound)` returns the argv), or `:none` when no
  # player binary is on the path. Public (undocumented) and OS-injectable so the
  # per-platform player order is tested deterministically.
  @doc false
  @spec player_command({atom(), atom()} | term(), (String.t() -> String.t() | nil)) ::
          {String.t(), (String.t() -> [String.t()])} | :none
  def player_command(os_type, find_executable_fn) when is_function(find_executable_fn, 1) do
    os_type
    |> player_candidates()
    |> Enum.find_value(:none, fn {binary, build_args} ->
      case find_executable_fn.(binary) do
        path when is_binary(path) and path != "" -> {path, build_args}
        _ -> false
      end
    end)
  end

  # macOS ships `afplay`; Linux desktops vary, so probe the common players in
  # preference order. `canberra-gtk-play` takes `-f <file>`; the rest take a
  # bare path.
  defp player_candidates({:unix, :darwin}), do: [{"afplay", &[&1]}]

  defp player_candidates({:unix, _}) do
    [
      {"paplay", &[&1]},
      {"canberra-gtk-play", &["-f", &1]},
      {"aplay", &[&1]}
    ]
  end

  defp player_candidates(_os_type), do: []
end
