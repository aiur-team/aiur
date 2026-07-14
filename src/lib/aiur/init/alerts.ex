defmodule Aiur.Init.Alerts do
  @moduledoc """
  Alert-sound opt-in flow for `aiur init`.

  This module owns the master alert prompt, global-alerts reuse offer, and the
  never-clobber `.aiur/alerts` writer that selects the host OS template.
  """

  alias Aiur.Init.{Format, Scaffold, Templates}

  @alerts_file_name "alerts"

  # A final opt-in for cross-platform alert sounds. The first question is the
  # on/off master switch; on "yes" a second question lets the Executor pick the
  # built-in macOS/Linux OS-default set or the fully customizable topic→sound map
  # — pointing them at the `.aiur/alerts` file init scaffolds so the customization
  # surface is discoverable, not just the on/off setting. Either way init writes
  # `.aiur/alerts`; the map is only consulted when OS-default sounds are off.
  # Sounds are machine-level, so this is offered for global configs too (unlike
  # prewarm, which is per-repo).
  @doc false
  @spec prompt_alerts(Aiur.Init.io(), Aiur.Init.deps(), Path.t()) :: map()
  def prompt_alerts(io, deps, target) do
    if io.confirm.("Add sound effects for alerts (e.g. an agent is stuck or needs your input)?", false) do
      io.puts.([
        "aiur scaffolds an editable ",
        Format.dim(".aiur/alerts"),
        " map so you can set a custom sound per event."
      ])

      source_path = prompt_reuse_global_alerts(io, deps, target)
      use_os = io.confirm.("Use the built-in OS default sounds? (No = play the custom .aiur/alerts mapping)", true)
      %{enabled: true, use_os_default_sounds: use_os, source_path: source_path}
    else
      %{enabled: false, use_os_default_sounds: false, source_path: nil}
    end
  end

  @doc false
  @spec prompt_reuse_global_alerts(Aiur.Init.io(), Aiur.Init.deps(), Path.t()) :: Path.t() | nil
  def prompt_reuse_global_alerts(io, deps, _target) do
    source = deps.global_alerts_path.()

    case deps.existing_alerts_path.(source) do
      nil ->
        nil

      path ->
        if io.confirm.(
             "Found an existing alerts file at ~/.aiur/alerts — copy it into this repo's .aiur/alerts?",
             true
           ) do
          path
        end
    end
  end

  # The scaffolded config references the alert sound map via `alerts_file: alerts`,
  # so make sure `.aiur/alerts` exists (created from the host's alerts example).
  # Never clobber an existing one — the Executor may have tuned the topic→sound map.
  @doc false
  @spec ensure_alerts(Aiur.Init.io(), Aiur.Init.deps(), Path.t(), map()) :: :ok
  def ensure_alerts(io, deps, target, alerts) do
    case deps.ensure_alerts.(target, alerts.source_path) do
      {:created, path} -> io.puts.(["Created: ", Format.dim(path)])
      {:exists, _path} -> :ok
    end
  end

  @doc false
  @spec write_alerts_file(Path.t(), Path.t() | nil) :: {:created | :exists, Path.t()}
  def write_alerts_file(target, source_path) do
    path = Path.join(Path.dirname(target), @alerts_file_name)

    if File.regular?(path) do
      {:exists, path}
    else
      write_new_alerts_file(path, source_path)
    end
  end

  @doc false
  @spec write_new_alerts_file(Path.t(), Path.t() | nil) :: {:created | :exists, Path.t()}
  def write_new_alerts_file(path, source_path) when is_binary(source_path) do
    if Scaffold.same_path?(path, source_path) do
      {:exists, path}
    else
      File.cp!(source_path, path)
      {:created, path}
    end
  end

  def write_new_alerts_file(path, _source_path) do
    File.write!(path, Templates.alerts_template(:os.type()))
    {:created, path}
  end
end
