defmodule Aiur.Config.Overrides do
  @moduledoc """
  Persistent, per-instance runtime configuration overrides.

  Override values are merged into the parsed workflow before the ordinary
  configuration schema validates it. The YAML file remains the source of
  defaults and is never rewritten.
  """

  require Logger

  alias Aiur.{Alerts, BuildStamp, Config, Fs, Workflow}
  alias Aiur.Config.{InstanceKey, Paths}
  alias Aiur.WorkflowStore.ReloadRejection

  @version 1
  @filename "config-overrides.json"
  @rejected_prefix "config-overrides.rejected-"
  @rejected_topic "config.override_rejected"

  @settings %{
    "agent.max_concurrent_builds" => %{path: ["agent", "max_concurrent_builds"], applies: "live"},
    "agent.max_concurrent_agents_by_state" => %{path: ["agent", "max_concurrent_agents_by_state"], applies: "live"},
    "agent.priority" => %{path: ["agent", "priority"], applies: "live"},
    "agent.routing" => %{path: ["agent", "routing"], applies: "live"},
    "build_queue.max_active_sets" => %{path: ["build_queue", "max_active_sets"], applies: "live"},
    "instance.ignore.tickets" => %{path: ["instance", "ignore", "tickets"], applies: "live"}
  }

  @doc "Merges every override accepted by this build into `workflow`."
  @spec apply(Workflow.loaded_workflow()) :: {:ok, Workflow.loaded_workflow()}
  def apply(workflow) when is_map(workflow) do
    with {:ok, workflow, _stamp} <- apply_with_stamp(workflow), do: {:ok, workflow}
  end

  @doc false
  @spec apply_with_stamp(Workflow.loaded_workflow()) ::
          {:ok, Workflow.loaded_workflow(), non_neg_integer() | nil}
  def apply_with_stamp(workflow) when is_map(workflow) do
    case path() do
      {:ok, path} -> apply_path(workflow, path)
      {:error, _identity_unavailable} -> {:ok, workflow, nil}
    end
  end

  @doc "Stores one already-decoded JSON value after validating the complete candidate configuration."
  @spec set(String.t(), term(), String.t()) :: {:ok, map()} | {:error, term()}
  def set(key, value, actor) when is_binary(key) and is_binary(actor) do
    with {:ok, setting} <- setting(key),
         {:ok, path} <- path(),
         {:ok, workflow} <- Workflow.load_base() do
      mutate(path, workflow, &set_state(&1, &2, path, key, value, actor, setting))
    end
  end

  @doc "Removes one runtime override. The YAML value becomes effective on the next reload."
  @spec unset(String.t(), String.t()) :: {:ok, :removed | :not_set} | {:error, term()}
  def unset(key, actor) when is_binary(key) and is_binary(actor) do
    with {:ok, _setting} <- setting(key),
         {:ok, path} <- path(),
         {:ok, workflow} <- Workflow.load_base() do
      mutate(path, workflow, &unset_state(&1, &2, path, key))
    end
  end

  @doc "Lists active override entries in dotted-key order."
  @spec list() :: {:ok, [map()]} | {:error, term()}
  def list do
    with {:ok, path} <- path(),
         {:ok, workflow} <- Workflow.load_base() do
      mutate(path, workflow, &list_state/2)
    end
  end

  @doc false
  @spec allowed_settings() :: map()
  def allowed_settings, do: @settings

  @doc false
  @spec path() :: {:ok, Path.t()} | {:error, atom()}
  def path do
    with {:ok, key} <- InstanceKey.current() do
      {:ok, Path.join([Paths.dashboard_secret_root(), "instances", key, @filename])}
    end
  end

  @doc false
  @spec stamp() :: non_neg_integer() | nil
  def stamp do
    with {:ok, path} <- path(),
         {:ok, body} <- File.read(path) do
      :erlang.phash2(body)
    else
      _unavailable -> nil
    end
  end

  @doc false
  @spec build_version() :: String.t()
  def build_version do
    version = to_string(Application.spec(:aiur, :vsn) || "unknown")
    build_sha = BuildStamp.read()["source_sha"]

    case build_sha do
      sha when is_binary(sha) -> "#{version}+#{String.slice(sha, 0, 7)}"
      _unknown -> version
    end
  end

  defp set_state(state, active_workflow, path, key, value, actor, setting) do
    revision = state["revision"] + 1
    entry = override_entry(value, revision, actor)
    candidate = put_setting(active_workflow, setting.path, value)

    case ReloadRejection.validate(candidate) do
      :ok -> persist_set(path, state, key, entry, setting)
      {:error, reason} -> {:error, reason}
    end
  end

  defp override_entry(value, revision, actor) do
    %{
      "value" => value,
      "revision" => revision,
      "set_by" => actor,
      "set_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "build" => build_version()
    }
  end

  defp persist_set(path, state, key, entry, setting) do
    next = %{state | "revision" => entry["revision"], "entries" => Map.put(state["entries"], key, entry)}

    with :ok <- write_state(path, next), do: {:ok, list_entry(key, entry, setting)}
  end

  defp unset_state(state, _active_workflow, path, key) do
    if Map.has_key?(state["entries"], key) do
      revision = state["revision"] + 1
      next = %{state | "revision" => revision, "entries" => Map.delete(state["entries"], key)}

      with :ok <- write_state(path, next), do: {:ok, :removed}
    else
      {:ok, :not_set}
    end
  end

  defp list_state(state, _active_workflow) do
    entries =
      state["entries"]
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, entry} -> list_entry(key, entry, Map.fetch!(@settings, key)) end)

    {:ok, entries}
  end

  defp apply_path(workflow, path) do
    {result, rejected, persistence_error, stamp} =
      locked(path, fn ->
        case read_state(path) do
          {:ok, state} ->
            {active_workflow, active_state, rejected} = partition(workflow, state)
            persistence_error = persist_rejections(path, state, active_state, rejected)
            {{:ok, active_workflow}, rejected, persistence_error, file_stamp(path)}

          {:error, :enoent} ->
            {{:ok, workflow}, %{}, nil, nil}

          {:error, reason} ->
            persistence_error = quarantine_invalid_file(path)
            {{:ok, workflow}, %{"<file>" => inspect(reason)}, persistence_error, file_stamp(path)}
        end
      end)

    maybe_alert_rejections(path, rejected, persistence_error)
    with {:ok, workflow} <- result, do: {:ok, workflow, stamp}
  end

  defp mutate(path, workflow, fun) do
    case locked(path, fn -> mutation_state(path, workflow, fun) end) do
      {:mutation, result, rejected} ->
        maybe_alert_rejections(path, rejected, nil)
        result

      result ->
        result
    end
  end

  defp mutation_state(path, workflow, fun) do
    case read_state(path) do
      {:ok, state} ->
        {active_workflow, active_state, rejected} = partition(workflow, state)

        case persist_rejections(path, state, active_state, rejected) do
          nil -> {:mutation, fun.(active_state, active_workflow), rejected}
          reason -> {:mutation, {:error, reason}, rejected}
        end

      {:error, :enoent} ->
        {:mutation, fun.(empty_state(), workflow), %{}}

      {:error, reason} ->
        {:error, {:invalid_override_file, reason}}
    end
  end

  defp partition(workflow, state) do
    state["entries"]
    |> Enum.sort_by(fn {key, entry} -> {entry_revision(entry), key} end)
    |> Enum.reduce({workflow, %{}, %{}}, fn {key, entry}, {candidate, accepted, rejected} ->
      case apply_entry(candidate, key, entry) do
        {:ok, next} -> {next, Map.put(accepted, key, entry), rejected}
        {:error, reason} -> {candidate, accepted, Map.put(rejected, key, format_reason(reason))}
      end
    end)
    |> then(fn {active_workflow, accepted, rejected} ->
      {active_workflow, %{state | "entries" => accepted}, rejected}
    end)
  end

  defp apply_entry(workflow, key, entry) do
    with {:ok, setting} <- setting(key),
         :ok <- validate_entry(entry) do
      candidate = put_setting(workflow, setting.path, entry["value"])

      case ReloadRejection.validate(candidate) do
        :ok -> {:ok, candidate}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_entry(%{"value" => _value, "revision" => revision, "set_by" => actor, "set_at" => set_at, "build" => build})
       when is_integer(revision) and revision > 0 and is_binary(actor) and actor != "" and is_binary(set_at) and set_at != "" and is_binary(build) and build != "",
       do: :ok

  defp validate_entry(_entry), do: {:error, :invalid_override_entry}

  defp setting(key) do
    case Map.fetch(@settings, key) do
      {:ok, setting} -> {:ok, setting}
      :error -> {:error, {:unknown_setting, build_version()}}
    end
  end

  defp put_setting(%{config: config} = workflow, path, value) do
    %{workflow | config: deep_put(config, path, value)}
  end

  defp deep_put(map, [key], value), do: Map.put(map, key, value)

  defp deep_put(map, [key | rest], value) do
    nested =
      case Map.get(map, key) do
        value when is_map(value) -> value
        _missing -> %{}
      end

    Map.put(map, key, deep_put(nested, rest, value))
  end

  defp read_state(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         :ok <- validate_state(decoded) do
      {:ok, decoded}
    end
  end

  defp validate_state(%{"version" => @version, "revision" => revision, "entries" => entries})
       when is_integer(revision) and revision >= 0 and is_map(entries),
       do: :ok

  defp validate_state(%{"version" => version}), do: {:error, {:unsupported_override_version, version}}
  defp validate_state(_state), do: {:error, :invalid_override_document}

  defp empty_state, do: %{"version" => @version, "revision" => 0, "entries" => %{}}

  defp write_state(path, state) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      Fs.atomic_write(path, Jason.encode!(state, pretty: true) <> "\n", fsync: true, mode: 0o600)
    end
  end

  defp persist_rejections(_path, _original, _active, rejected) when map_size(rejected) == 0, do: nil

  defp persist_rejections(path, original, active, rejected) do
    rejected_entries = Map.take(original["entries"], Map.keys(rejected))

    document = %{
      "version" => @version,
      "revision" => original["revision"],
      "entries" => rejected_entries,
      "reasons" => rejected
    }

    rejected_path = rejected_path(path)

    with :ok <- Fs.atomic_write(rejected_path, Jason.encode!(document, pretty: true) <> "\n", fsync: true, mode: 0o600),
         :ok <- write_state(path, active) do
      nil
    else
      {:error, reason} -> {:override_quarantine_failed, reason}
    end
  end

  defp quarantine_invalid_file(path) do
    case File.rename(path, rejected_path(path)) do
      :ok -> nil
      {:error, :enoent} -> nil
      {:error, reason} -> {:override_quarantine_failed, reason}
    end
  end

  defp rejected_path(path) do
    Path.join(Path.dirname(path), @rejected_prefix <> Integer.to_string(System.system_time(:microsecond)) <> ".json")
  end

  defp locked(path, fun), do: :global.trans({__MODULE__, path}, fun)

  defp file_stamp(path) do
    case File.read(path) do
      {:ok, body} -> :erlang.phash2(body)
      {:error, _reason} -> nil
    end
  end

  defp entry_revision(%{"revision" => revision}) when is_integer(revision), do: revision
  defp entry_revision(_entry), do: 0

  defp list_entry(key, entry, setting) do
    %{
      key: key,
      value: entry["value"],
      source: "override",
      revision: entry["revision"],
      actor: entry["set_by"],
      set_at: entry["set_at"],
      build: entry["build"],
      applies: setting.applies
    }
  end

  defp format_reason({:unknown_setting, version}), do: "unknown setting on this build (#{version})"
  defp format_reason(:invalid_override_entry), do: "invalid override entry"
  defp format_reason(reason), do: Config.format_config_error(reason)

  defp maybe_alert_rejections(_path, rejected, _persistence_error) when map_size(rejected) == 0, do: :ok

  defp maybe_alert_rejections(path, rejected, persistence_error) do
    keys = rejected |> Map.keys() |> Enum.sort() |> Enum.join(", ")
    persistence = if persistence_error, do: "; quarantine error: #{inspect(persistence_error)}", else: ""
    reason = "Rejected runtime config overrides: #{keys}#{persistence}"

    Logger.warning("#{reason} path=#{path}")

    safe_alert(
      message: "Runtime config overrides rejected: #{keys}",
      reason: reason,
      needs_attention: true,
      severity: "warning"
    )
  end

  defp safe_alert(opts) do
    Alerts.emit_system(@rejected_topic, opts)
    :ok
  rescue
    error ->
      Logger.warning("config override rejection alert failed: #{Exception.message(error)}")
      :ok
  catch
    _kind, _reason -> :ok
  end
end
