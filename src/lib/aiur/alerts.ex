defmodule Aiur.Alerts do
  @moduledoc """
  Loads alert definitions, emits structured alert events, and optionally plays
  one configured sound clip.
  """

  require Logger

  alias Aiur.{AgentEventLog, AgentEvents, AgentPubSub, AlertFeed, AlertLedger, Config, Issue, Workflow}
  alias Aiur.Config.Paths
  alias Aiur.Config.Schema.Alerts, as: AlertConfig
  alias Aiur.Events.{Publisher, Topic}
  alias AiurWeb.ObservabilityPubSub

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

  @type definition :: %{
          message: String.t(),
          sound: [String.t()]
        }

  @doc """
  Returns the raw YAML-derived alert definitions as a map keyed by
  pattern string. Insertion order is not preserved; for matching, use
  `definition_for_topic/1` which sorts by specificity.
  """
  @spec definitions() :: %{optional(String.t()) => definition()}
  def definitions do
    alerts_path()
    |> load_yaml()
    |> Map.get("alerts", %{})
    |> normalize_definitions()
  end

  @doc """
  Returns the alert definition whose YAML pattern key matches `topic`
  via `Aiur.Events.Topic.matches?/2`. Walks patterns in specificity
  order (more literal segments → first); ties broken lexicographically.
  Returns `nil` if no pattern matches.
  """
  @spec definition_for_topic(String.t()) :: definition() | nil
  def definition_for_topic(topic) when is_binary(topic) do
    Enum.find_value(sorted_patterns(), fn {pattern, definition} ->
      if Topic.matches?(pattern, topic), do: definition
    end)
  end

  def definition_for_topic(_topic), do: nil

  defp sorted_patterns do
    definitions()
    |> Enum.to_list()
    |> Enum.sort_by(fn {pattern, _def} -> {-Topic.specificity_score(pattern), pattern} end)
  end

  @spec emit_system(String.t(), keyword()) :: :ok | {:error, term()}
  def emit_system(name, opts \\ []) when is_binary(name) do
    do_emit(name, Keyword.get(opts, :message), Keyword.put(opts, :event_source, :system))
  end

  @spec emit_custom(String.t(), String.t()) :: :ok | {:error, term()}
  def emit_custom(name, message) when is_binary(name) and is_binary(message) do
    emit_custom(name, message, [])
  end

  @spec emit_custom(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def emit_custom(name, message, opts)
      when is_binary(name) and is_binary(message) do
    do_emit(name, message, Keyword.put_new(opts, :event_source, :agent))
  end

  def emit_custom(_name, _message, _opts), do: {:error, :invalid_alert}

  defp do_emit(topic, override_message, opts) do
    if repeat_resolution?(topic) do
      :ok
    else
      emit_alert(topic, override_message, opts)
    end
  end

  # A `.resolved` alert reports the firing → cleared transition. Emitting it
  # again while the condition has stayed clear reports a state as if it were a
  # transition, and a poller doing so every cycle buries every record an
  # Executor would act on. The check is against the durable ledger rather than
  # caller-held state, so an emitter that loses its in-memory latch — a restart,
  # a fresh CLI process — still cannot replay a transition that already landed.
  # Reads with the same default options `write_alert_ledger_entry/3` appends
  # under, so the gate can never consult a ledger the emit would not land in.
  # Fails open: an unreadable ledger must not swallow a real transition.
  defp repeat_resolution?(topic) do
    AlertFeed.duplicate_resolution?(topic)
  rescue
    _unavailable -> false
  end

  defp emit_alert(topic, override_message, opts) do
    config = definition_for_topic(topic)
    message = override_message || config_message(config)

    # Always publish through the Exchange — even when there's no matching
    # alert entry. Subscribers to the topic bus see every alert-emitted
    # event, regardless of whether the Executor-facing sound/badge fires.
    metadata = alert_metadata(message, opts)
    publish_to_exchange(topic, message, metadata, opts)

    with {:ok, message} <- present_string(message, :missing_message) do
      settings = alert_settings()
      selected_sound = select_sound(topic, config, settings)

      payload = %{
        "event" => "alert",
        "name" => topic,
        "topic" => topic,
        "message" => message,
        "reason" => metadata.reason,
        "severity" => metadata.severity,
        "needs_attention" => metadata.needs_attention,
        "source_ticket_id" => metadata.source_ticket_id,
        "sound" => selected_sound
      }

      workspace = Keyword.get(opts, :workspace) || resolve_workspace(Keyword.get(opts, :issue))
      worker_host = Keyword.get(opts, :worker_host)

      Logger.info("[alert]#{identifier_suffix(opts)} #{topic}: #{message}")

      timestamp = DateTime.utc_now()

      alert_event = %{
        event: :alert,
        timestamp: timestamp,
        name: topic,
        topic: topic,
        message: message,
        reason: metadata.reason,
        severity: metadata.severity,
        needs_attention: metadata.needs_attention,
        source_ticket_id: metadata.source_ticket_id,
        sound: selected_sound,
        raw: Jason.encode!(payload)
      }

      AgentEventLog.write(workspace, worker_host, alert_event)
      write_alert_ledger_entry(alert_event, workspace, worker_host)
      maybe_write_central_alert_feed_entry(alert_event, workspace, worker_host, opts)

      maybe_play_sound(selected_sound, settings, opts)
      broadcast_agent_alert(topic, message, metadata, selected_sound, opts)
      ObservabilityPubSub.broadcast_update()
      :ok
    end
  end

  defp alert_metadata(message, opts) do
    needs_attention = Keyword.get(opts, :needs_attention) == true

    %{
      reason: alert_reason(message, opts),
      severity: alert_severity(needs_attention, opts),
      needs_attention: needs_attention,
      source_ticket_id: issue_number_for(opts)
    }
  end

  defp alert_reason(message, opts) do
    opts
    |> Keyword.get(:reason)
    |> present_string()
    |> case do
      {:ok, reason} -> reason
      _ -> message || ""
    end
  end

  defp alert_severity(needs_attention, opts) do
    opts
    |> Keyword.get(:severity)
    |> present_string()
    |> case do
      {:ok, severity} -> severity
      _ when needs_attention -> "warning"
      _ -> "info"
    end
  end

  defp write_alert_ledger_entry(alert_event, workspace, worker_host) do
    agent =
      cond do
        is_binary(worker_host) -> "system"
        is_binary(workspace) -> Path.basename(workspace)
        true -> "system"
      end

    alert_event
    |> central_alert_json()
    |> Map.put("agent", agent)
    |> AlertLedger.append()
  end

  # Keep the historical central file as an audit-compatible auxiliary output.
  # AlertFeed reads the project-scoped ledger above, which also receives local
  # workspace alerts that intentionally remain absent from this file.
  defp maybe_write_central_alert_feed_entry(alert_event, workspace, worker_host, opts) do
    if is_binary(workspace) and worker_host == nil and not Keyword.get(opts, :central, false) do
      :ok
    else
      write_central_alert_feed_entry(alert_event)
    end
  end

  defp write_central_alert_feed_entry(alert_event) do
    path = Path.join(Paths.log_root_dir(), "alerts.ndjson")

    encoded =
      alert_event
      |> central_alert_json()
      |> Jason.encode!()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, encoded <> "\n", [:append]) do
      :ok
    else
      {:error, reason} ->
        Logger.debug("Failed writing central alert feed path=#{path} reason=#{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.debug("Failed writing central alert feed error=#{Exception.message(error)}")
      :ok
  end

  defp central_alert_json(alert_event) do
    Map.new(alert_event, fn
      {:timestamp, %DateTime{} = timestamp} -> {"timestamp", DateTime.to_iso8601(timestamp)}
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp publish_to_exchange(topic, message, metadata, opts) do
    payload =
      %{
        "message" => message || "",
        "source" => "alert",
        "reason" => metadata.reason,
        "severity" => metadata.severity,
        "needs_attention" => metadata.needs_attention,
        "source_ticket_id" => metadata.source_ticket_id,
        "topic" => topic,
        source: Keyword.get(opts, :event_source, :system)
      }
      |> Map.merge(Keyword.get(opts, :exchange_payload, %{}))

    Publisher.publish(topic, payload,
      issue_number: issue_number_for(opts),
      identity: Keyword.get(opts, :observation_identity),
      observation_source: Keyword.get(opts, :observation_source),
      observation_provenance: Keyword.get(opts, :observation_provenance),
      occurred_at: Keyword.get(opts, :occurred_at)
    )

    :ok
  rescue
    # Publisher GenServer may not be running during early-boot or test
    # configurations — never block the alert pipeline on its absence.
    _ -> :ok
  catch
    # A missing IdGenerator makes Publisher.publish/3 exit through its
    # GenServer call. Alerts must still reach the local feed in that failure
    # mode; otherwise the liveness signal itself disappears with the worker.
    :exit, _reason -> :ok
  end

  defp issue_number_for(opts) do
    case Keyword.get(opts, :issue) do
      %Issue{identifier: id} when is_binary(id) -> id
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp broadcast_agent_alert(name, message, metadata, selected_sound, opts) do
    case identifier_for_alert(opts) do
      identifier when is_binary(identifier) ->
        event =
          AgentEvents.alert_event(name, message,
            reason: metadata.reason,
            severity: metadata.severity,
            needs_attention: metadata.needs_attention,
            source_ticket_id: metadata.source_ticket_id,
            sound: selected_sound
          )

        AgentPubSub.broadcast_alert(identifier, event)

      _ ->
        :ok
    end
  end

  defp identifier_for_alert(opts) do
    case Keyword.get(opts, :issue) do
      %Issue{identifier: identifier} when is_binary(identifier) -> identifier
      identifier when is_binary(identifier) -> identifier
      _ -> Keyword.get(opts, :identifier)
    end
  end

  defp identifier_suffix(opts) do
    case identifier_for_alert(opts) do
      identifier when is_binary(identifier) and identifier != "" -> " (##{identifier})"
      _ -> ""
    end
  end

  # Path precedence: the `:alerts_file_path` app-env override (tests) wins, then
  # the config `alerts.alerts_file`, then the default `<config-dir>/alerts`.
  defp alerts_path do
    cond do
      override = Application.get_env(:aiur, :alerts_file_path) ->
        override

      path = configured_alerts_file() ->
        path

      true ->
        default = default_alerts_path()
        warn_if_legacy_yaml_only(default)
        default
    end
  end

  # The `.aiur/alerts.yaml` fallback was removed: only the extensionless
  # `.aiur/alerts` file (or an explicit `alerts_file`) is loaded now. When the
  # canonical file is absent but a legacy `.aiur/alerts.yaml` still sits next to
  # the config, the mappings silently resolve to `%{}` and every alert goes
  # quiet with no signal. Warn once — keyed on the legacy path via
  # `:persistent_term`, so a single VM logs it a single time — so the Executor
  # knows to rename the file. The yaml is never read; only its presence is
  # detected.
  defp warn_if_legacy_yaml_only(nil), do: :ok

  defp warn_if_legacy_yaml_only(path) do
    legacy = path <> ".yaml"

    if not File.exists?(path) and File.exists?(legacy) do
      warn_legacy_yaml_once(path, legacy)
    end

    :ok
  end

  defp warn_legacy_yaml_once(path, legacy) do
    key = {__MODULE__, :legacy_yaml_warned, legacy}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning(
        "Alert sounds are disabled: the `.aiur/alerts.yaml` fallback was removed. " <>
          "Found #{legacy} but no #{path}. Rename #{legacy} to #{path} " <>
          "(drop the `.yaml` extension) to restore alert sounds."
      )
    end

    :ok
  end

  # The default alert definitions live alongside the aiur config, at
  # `<config-dir>/alerts` (i.e. `.aiur/alerts`). Resolved at RUNTIME
  # from the active config path rather than a compile-time module attribute, so
  # it tracks the Executor’s `.aiur/` directory and resolves correctly inside an
  # assembled release/escript (a baked source path would not).
  defp default_alerts_path do
    case Workflow.workflow_file_path() do
      path when is_binary(path) and path != "" -> Path.join(Path.dirname(path), "alerts")
      _ -> nil
    end
  end

  # A configured `alerts_file` is only honoured when it actually exists, so a
  # typo'd or missing custom path falls back to the default `<config-dir>/alerts` rather
  # than silently dropping every alert sound. Relative paths are pre-resolved
  # against the config dir at load time (see `Aiur.Workflow`), so by here the
  # value is already absolute or a `~/`-prefixed path expanded below.
  defp configured_alerts_file do
    case alert_settings().alerts_file do
      file when is_binary(file) and file != "" ->
        expanded = expand_sound_path(file)
        if File.exists?(expanded), do: expanded

      _ ->
        nil
    end
  end

  defp load_yaml(path) when is_binary(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = yaml} -> yaml
      _ -> %{}
    end
  end

  defp load_yaml(_path), do: %{}

  defp normalize_definitions(definitions) when is_map(definitions) do
    Enum.reduce(definitions, %{}, fn {key, value}, acc ->
      case normalize_definition(key, value) do
        {:ok, name, definition} -> Map.put(acc, name, definition)
        :skip -> acc
      end
    end)
  end

  defp normalize_definitions(_definitions), do: %{}

  defp normalize_definition(key, value) do
    fallback_name = to_string(key)

    case value do
      %{} = map ->
        message = map_value(map, "message")

        case present_string(message) do
          {:ok, message} ->
            {:ok, fallback_name,
             %{
               message: message,
               sound: normalize_sounds(map_value(map, "sound"))
             }}

          _ ->
            :skip
        end

      _ ->
        :skip
    end
  end

  # Currently invoked only with the literal keys `"message"` and
  # `"sound"`; the extra fallback clause that existed previously was
  # unreachable so we keep this strict for clarity.
  defp map_value(map, "message"), do: Map.get(map, "message") || Map.get(map, :message)
  defp map_value(map, "sound"), do: Map.get(map, "sound") || Map.get(map, :sound)

  defp normalize_sounds(nil), do: []
  defp normalize_sounds(sound) when is_binary(sound), do: [sound]

  defp normalize_sounds(sounds) when is_list(sounds) do
    sounds
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_sounds(_sounds), do: []

  defp config_message(%{message: message}), do: message
  defp config_message(_config), do: nil

  defp config_sounds(%{sound: sounds}), do: sounds
  defp config_sounds(_config), do: []

  defp present_string(value, reason \\ :missing_string)

  defp present_string(value, reason) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, reason}
      trimmed -> {:ok, trimmed}
    end
  end

  defp present_string(_value, reason), do: {:error, reason}

  # Resolved alert settings, falling back to schema defaults whenever the config
  # can't be loaded (early boot, tests) so emission never crashes a turn.
  defp alert_settings do
    case Config.alerts_settings() do
      {:ok, settings} -> settings
      _ -> %AlertConfig{}
    end
  rescue
    _ -> %AlertConfig{}
  end

  # `use_os_default_sounds: false` (default) uses the topic→sound mapping from
  # the alerts file; `true` maps the alert's category to a built-in OS system sound
  # (with a `sound_dir` per-category override).
  defp select_sound(topic, _definition, %{use_os_default_sounds: true} = settings) do
    os_default_sound(topic, settings)
  end

  defp select_sound(_topic, definition, settings) do
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
  defp resolve_sound_path("~/" <> _ = path, _sound_dir), do: expand_sound_path(path)
  defp resolve_sound_path("/" <> _ = path, _sound_dir), do: path

  defp resolve_sound_path(name, sound_dir) when is_binary(sound_dir) and sound_dir != "",
    do: Path.join(expand_sound_path(sound_dir), name)

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
    base = expand_sound_path(sound_dir)
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
  defp expand_sound_path("~/" <> rest = path) do
    case System.user_home() do
      home when is_binary(home) -> Path.join(home, rest)
      _ -> path
    end
  end

  defp expand_sound_path(path), do: path

  # `enabled: false` gates all playback; a nil sound (nothing matched / no OS
  # default present) is a silent no-op.
  defp maybe_play_sound(_sound, %{enabled: false}, _opts), do: :ok
  defp maybe_play_sound(nil, _settings, _opts), do: :ok

  defp maybe_play_sound(sound, _settings, opts) do
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

  defp resolve_workspace(%Issue{identifier: identifier}), do: resolve_workspace(identifier)

  defp resolve_workspace(identifier) when is_binary(identifier),
    do: resolve_workspace_for(identifier, &Config.workspace_root/0)

  defp resolve_workspace(_issue), do: nil

  # Public (but undocumented) so a test can inject a `workspace_root_fn`
  # that raises, exercising the rescue branch deterministically.
  @doc false
  @spec resolve_workspace_for(String.t(), (-> String.t())) :: String.t() | nil
  def resolve_workspace_for(identifier, workspace_root_fn)
      when is_binary(identifier) and is_function(workspace_root_fn, 0) do
    workspace = Aiur.Workspace.workspace_path_under(workspace_root_fn.(), identifier)

    if File.dir?(workspace), do: workspace, else: nil
  rescue
    _error -> nil
  end
end
