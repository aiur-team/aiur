defmodule SymphonyElixir.Alerts do
  @moduledoc """
  Loads alert definitions, emits structured alert events, and optionally plays
  one configured sound clip.
  """

  require Logger

  alias SymphonyElixir.{AgentEventLog, Config, Issue, StatusDashboard}

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

      Logger.info("[alert] #{name}: #{message}")

      AgentEventLog.write(workspace, worker_host, %{
        event: :alert,
        timestamp: DateTime.utc_now(),
        name: name,
        message: message,
        sound: selected_sound,
        raw: Jason.encode!(payload)
      })

      maybe_play_sound(selected_sound, opts)
      StatusDashboard.notify_update()
      :ok
    end
  end

  defp alerts_path do
    Application.get_env(:symphony_elixir, :alerts_file_path, @alerts_path)
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

  defp map_value(map, key) do
    case key do
      "message" -> Map.get(map, "message") || Map.get(map, :message)
      "sound" -> Map.get(map, "sound") || Map.get(map, :sound)
      _ -> Map.get(map, key)
    end
  end

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
    Mix.env() == :test and not Keyword.has_key?(opts, :player)
  end

  defp default_player("http://" <> _url), do: :ok
  defp default_player("https://" <> _url), do: :ok

  defp default_player(sound) when is_binary(sound) do
    executable = System.find_executable("afplay")

    cond do
      is_nil(executable) -> :ok
      not File.exists?(sound) -> :ok
      true -> Task.start(fn -> System.cmd(executable, [sound], stderr_to_stdout: true) end)
    end
  end

  defp resolve_workspace(%Issue{identifier: identifier}), do: resolve_workspace(identifier)

  defp resolve_workspace(identifier) when is_binary(identifier) do
    workspace =
      Config.workspace_root()
      |> Path.join(safe_identifier(identifier))

    if File.dir?(workspace), do: workspace, else: nil
  rescue
    _error -> nil
  end

  defp resolve_workspace(_issue), do: nil

  defp safe_identifier(identifier) do
    String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
  end
end
