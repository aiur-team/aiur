defmodule Aiur.Alerts.Config do
  @moduledoc false

  require Logger

  alias Aiur.Alerts.Sound
  alias Aiur.Config, as: RuntimeConfig
  alias Aiur.Config.Schema.Alerts, as: AlertConfig
  alias Aiur.Workflow

  @spec definitions() :: %{optional(String.t()) => Aiur.Alerts.definition()}
  def definitions do
    alerts_path()
    |> load_yaml()
    |> Map.get("alerts", %{})
    |> normalize_definitions()
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
    key = {Aiur.Alerts, :legacy_yaml_warned, legacy}

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
    case settings().alerts_file do
      file when is_binary(file) and file != "" ->
        expanded = Sound.expand_path(file)
        if File.exists?(expanded), do: expanded

      _ ->
        nil
    end
  end

  defp load_yaml(path) when is_binary(path) do
    case Aiur.Yaml.read_from_file(path) do
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

  # Resolved alert settings, falling back to schema defaults whenever the config
  # can't be loaded (early boot, tests) so emission never crashes a turn.
  @doc false
  @spec settings() :: AlertConfig.t()
  def settings do
    case RuntimeConfig.alerts_settings() do
      {:ok, settings} -> settings
      _ -> %AlertConfig{}
    end
  rescue
    _ -> %AlertConfig{}
  end

  @doc false
  @spec present_string(term(), atom()) :: {:ok, String.t()} | {:error, atom()}
  def present_string(value, reason \\ :missing_string)

  def present_string(value, reason) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, reason}
      trimmed -> {:ok, trimmed}
    end
  end

  def present_string(_value, reason), do: {:error, reason}
end
