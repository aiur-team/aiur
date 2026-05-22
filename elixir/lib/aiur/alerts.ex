defmodule Aiur.Alerts do
  @moduledoc """
  Loads alert definitions, emits structured alert events, and optionally plays
  one configured sound clip.
  """

  require Logger

  alias Aiur.{AgentEventLog, AgentEvents, AgentPubSub, Config, Issue}
  alias AiurWeb.ObservabilityPubSub

  @alerts_path Path.expand("../../../alerts.yaml", __DIR__)
  @system_scopes ["task.", "agent.", "chat."]

  @type definition :: %{
          message: String.t(),
          sound: [String.t()]
        }

  @spec definitions() :: %{optional(String.t()) => definition()}
  def definitions do
    alerts_path()
    |> load_yaml()
    |> Map.get("alerts", %{})
    |> normalize_definitions()
  end

  @spec definition(String.t()) :: definition() | nil
  def definition(name) when is_binary(name), do: Map.get(definitions(), name)
  def definition(_name), do: nil

  @spec system_owned_name?(String.t()) :: boolean()
  def system_owned_name?(name) when is_binary(name) do
    Enum.any?(@system_scopes, &String.starts_with?(name, &1))
  end

  def system_owned_name?(_name), do: false

  @spec emit_system(String.t(), keyword()) :: :ok | {:error, term()}
  def emit_system(name, opts \\ []) when is_binary(name) do
    do_emit(name, nil, opts)
  end

  @spec emit_custom(String.t(), String.t()) :: :ok | {:error, term()}
  def emit_custom(name, message) when is_binary(name) and is_binary(message) do
    emit_custom(name, message, [])
  end

  @spec emit_custom(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def emit_custom(name, message, opts)
      when is_binary(name) and is_binary(message) do
    if system_owned_name?(name) do
      {:error, :system_scope_reserved}
    else
      do_emit(name, message, opts)
    end
  end

  def emit_custom(_name, _message, _opts), do: {:error, :invalid_alert}

  defp do_emit(name, override_message, opts) do
    config = definition(name)
    message = override_message || config_message(config)

    with {:ok, message} <- present_string(message, :missing_message) do
      selected_sound =
        config
        |> config_sounds()
        |> pick_sound()

      payload = %{
        "event" => "alert",
        "name" => name,
        "message" => message,
        "sound" => selected_sound
      }

      workspace = Keyword.get(opts, :workspace) || resolve_workspace(Keyword.get(opts, :issue))
      worker_host = Keyword.get(opts, :worker_host)

      Logger.info("[alert]#{identifier_suffix(opts)} #{name}: #{message}")

      AgentEventLog.write(workspace, worker_host, %{
        event: :alert,
        timestamp: DateTime.utc_now(),
        name: name,
        message: message,
        sound: selected_sound,
        raw: Jason.encode!(payload)
      })

      maybe_play_sound(selected_sound, opts)
      broadcast_agent_alert(name, message, selected_sound, opts)
      ObservabilityPubSub.broadcast_update()
      :ok
    end
  end

  defp broadcast_agent_alert(name, message, selected_sound, opts) do
    case identifier_for_alert(opts) do
      identifier when is_binary(identifier) ->
        event = AgentEvents.alert_event(name, message, sound: selected_sound)
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

  defp alerts_path do
    Application.get_env(:aiur, :alerts_file_path, @alerts_path)
  end

  defp load_yaml(path) when is_binary(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = yaml} -> yaml
      _ -> %{}
    end
  end

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

  defp pick_sound([]), do: nil
  defp pick_sound(sounds), do: sounds |> Enum.random() |> expand_sound_path()

  defp expand_sound_path("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand_sound_path(path), do: path

  defp maybe_play_sound(nil, _opts), do: :ok

  defp maybe_play_sound(sound, opts) do
    if test_env_without_player_override?(opts) do
      :ok
    else
      player = Keyword.get(opts, :player, &default_player/1)
      player.(sound)
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

  # Public (but undocumented) so tests can exercise the URL / missing-
  # binary / missing-file branches without round-tripping through
  # `maybe_play_sound`'s `test_env_without_player_override?/1`
  # short-circuit. The 2-arity form takes an injectable
  # `find_executable_fn` so tests can simulate a system on which
  # `afplay` is available.
  @doc false
  @spec default_player(String.t()) :: :ok | {:ok, pid()}
  def default_player(sound), do: default_player(sound, &System.find_executable/1)

  @doc false
  @spec default_player(String.t(), (String.t() -> String.t() | nil)) :: :ok | {:ok, pid()}
  def default_player("http://" <> _url, _find_executable_fn), do: :ok
  def default_player("https://" <> _url, _find_executable_fn), do: :ok

  def default_player(sound, find_executable_fn)
      when is_binary(sound) and is_function(find_executable_fn, 1) do
    executable = find_executable_fn.("afplay")

    cond do
      is_nil(executable) -> :ok
      not File.exists?(sound) -> :ok
      true -> Task.start(fn -> System.cmd(executable, [sound], stderr_to_stdout: true) end)
    end
  end

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
    workspace = Path.join(workspace_root_fn.(), safe_identifier(identifier))

    if File.dir?(workspace), do: workspace, else: nil
  rescue
    _error -> nil
  end

  defp safe_identifier(identifier) do
    String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
  end
end
