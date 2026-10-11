defmodule Aiur.TestSupport.WorkflowYaml.Sections do
  # Only renders an `alerts:` block when a test passes alerts overrides, so the
  # default generated config has no alerts section (exercising schema defaults).
  def alerts_yaml(overrides) do
    lines =
      [
        alerts_line("enabled", overrides, :alerts_enabled),
        alerts_line("use_os_default_sounds", overrides, :alerts_use_os_default_sounds),
        alerts_line("sound_dir", overrides, :alerts_sound_dir),
        alerts_line("alerts_file", overrides, :alerts_file)
      ]
      |> Enum.reject(&is_nil/1)

    if lines == [], do: nil, else: Enum.join(["alerts:" | lines], "\n")
  end

  defp alerts_line(key, overrides, override_key) do
    if Keyword.has_key?(overrides, override_key) do
      "  #{key}: #{yaml_value(Keyword.get(overrides, override_key))}"
    end
  end

  # Only renders a `pr_watch:` block when a test passes pr_watch overrides, so
  # the default generated config exercises the schema defaults (feature off).
  def pr_watch_yaml(overrides) do
    lines =
      [
        pr_watch_line("enabled", overrides, :pr_watch_enabled),
        pr_watch_line("watch_label", overrides, :pr_watch_watch_label),
        pr_watch_line("command_prefix", overrides, :pr_watch_command_prefix)
      ]
      |> Enum.reject(&is_nil/1)

    if lines == [], do: nil, else: Enum.join(["pr_watch:" | lines], "\n")
  end

  defp pr_watch_line(key, overrides, override_key) do
    if Keyword.has_key?(overrides, override_key) do
      "  #{key}: #{yaml_value(Keyword.get(overrides, override_key))}"
    end
  end

  def yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  def yaml_value(value) when is_integer(value), do: to_string(value)
  def yaml_value(true), do: "true"
  def yaml_value(false), do: "false"
  def yaml_value(nil), do: "null"

  def yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  def yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  def yaml_value(value), do: yaml_value(to_string(value))

  # Emits `polling.intervals` (per-class cadences, #2309) when the caller passed
  # a `:polling_intervals` map, e.g. %{"planning" => 600, "review" => 300}.
  def polling_intervals_yaml(config) do
    case Keyword.get(config, :polling_intervals) do
      nil ->
        nil

      intervals when is_map(intervals) and map_size(intervals) > 0 ->
        lines =
          intervals
          |> Enum.sort_by(fn {class, _seconds} -> to_string(class) end)
          |> Enum.map_join("\n", fn {class, seconds} -> "    #{class}: #{yaml_value(seconds)}" end)

        "  intervals:\n" <> lines

      _other ->
        nil
    end
  end

  def hooks_yaml(nil, nil, nil, nil, timeout_ms),
    do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  def hooks_yaml(
        hook_after_create,
        hook_before_run,
        hook_after_run,
        hook_before_remove,
        timeout_ms
      ) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  def worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
      when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
      do: nil

  def worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  def observability_yaml(enabled, writable, refresh_ms, render_interval_ms, retention_max_bytes, retention_max_age_days, retention_prune_interval_bytes) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      writable != nil && "  dashboard_writable: #{yaml_value(writable)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}",
      retention_max_bytes != nil && "  telemetry_retention_max_bytes: #{yaml_value(retention_max_bytes)}",
      retention_max_age_days != nil && "  telemetry_retention_max_age_days: #{yaml_value(retention_max_age_days)}",
      retention_prune_interval_bytes != nil &&
        "  telemetry_retention_prune_interval_bytes: #{yaml_value(retention_prune_interval_bytes)}"
    ]
    |> Enum.reject(&(&1 == false))
    |> Enum.join("\n")
  end

  def decisions_yaml(overrides) do
    lines =
      [
        decisions_line(
          "supervisor_allowed_kinds",
          overrides,
          :supervisor_decision_allowed_kinds
        ),
        decisions_line(
          "supervisor_allow_non_reversible",
          overrides,
          :supervisor_decision_allow_non_reversible
        )
      ]
      |> Enum.reject(&is_nil/1)

    if lines == [], do: nil, else: Enum.join(["decisions:" | lines], "\n")
  end

  defp decisions_line(key, overrides, override_key) do
    if Keyword.has_key?(overrides, override_key) do
      "  #{key}: #{yaml_value(Keyword.get(overrides, override_key))}"
    end
  end

  def server_yaml(nil, nil), do: nil

  def server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
