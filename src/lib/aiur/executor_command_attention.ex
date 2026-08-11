defmodule Aiur.ExecutorCommandAttention do
  @moduledoc false

  alias Aiur.{Alerts, JsonStore}
  alias Aiur.Config.Paths

  @spec topic(String.t(), String.t()) :: String.t()
  def topic(decision_id, ticket_id) when is_binary(decision_id) and is_binary(ticket_id) do
    "ticket.#{ticket_id}.agent.attention.executor-command-#{digest(decision_id)}"
  end

  @doc "Opens one durable, idempotent operator escalation per Command version."
  @spec open(map(), String.t(), String.t(), keyword()) :: {:ok, :opened | :already_open} | {:error, term()}
  def open(decision, executor_id, reason, opts \\ [])
      when is_map(decision) and is_binary(executor_id) and is_binary(reason) and is_list(opts) do
    with {:ok, decision_id, ticket_id, version} <- identity(decision),
         {:ok, path} <- marker_path(decision_id, opts),
         {:ok, marker} <- JsonStore.read(path) do
      maybe_open(marker, decision_id, ticket_id, version, executor_id, reason, path, opts)
    end
  end

  @doc "Clears a keyed operator escalation after any terminal Command decision."
  @spec resolve(map(), keyword()) :: :ok | {:error, term()}
  def resolve(decision, opts \\ []) when is_map(decision) and is_list(opts) do
    with {:ok, decision_id, ticket_id, _version} <- identity(decision),
         {:ok, path} <- marker_path(decision_id, opts),
         {:ok, marker} <- JsonStore.read(path) do
      maybe_resolve(marker, decision_id, ticket_id, path, opts)
    end
  end

  defp maybe_open(
         %{"decision_id" => decision_id, "version" => version, "state" => "open"},
         decision_id,
         _ticket_id,
         version,
         _executor_id,
         _reason,
         _path,
         _opts
       ),
       do: {:ok, :already_open}

  defp maybe_open(marker, decision_id, ticket_id, version, executor_id, reason, path, opts) do
    topic = topic(decision_id, ticket_id)
    message = "Executor #{executor_id} escalated Command #{decision_id}"
    alert_fun = Keyword.get(opts, :alert_fun, &emit_alert/3)

    pending = %{
      "decision_id" => decision_id,
      "version" => version,
      "state" => "pending",
      "executor_id" => executor_id,
      "reason" => reason
    }

    with :ok <- maybe_write_pending(marker, pending, path),
         :ok <- JsonStore.write!(path, %{pending | "state" => "open"}) do
      case deliver_alert(alert_fun, topic, message, ticket_id, reason) do
        :ok ->
          {:ok, :opened}

        {:error, _reason} = error ->
          JsonStore.write!(path, pending)
          error
      end
    end
  end

  defp deliver_alert(alert_fun, topic, message, ticket_id, reason) do
    alert_fun.(topic, message,
      issue: ticket_id,
      reason: reason,
      needs_attention: true,
      severity: "warning"
    )
  rescue
    error -> {:error, {:alert_unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:alert_unavailable, reason}}
  end

  defp maybe_write_pending(
         %{"decision_id" => decision_id, "version" => version, "state" => "pending"},
         %{"decision_id" => decision_id, "version" => version},
         _path
       ),
       do: :ok

  defp maybe_write_pending(_marker, pending, path), do: JsonStore.write!(path, pending)

  defp maybe_resolve(%{"decision_id" => decision_id}, decision_id, ticket_id, path, opts) do
    with :ok <- emit_resolution(decision_id, ticket_id, topic(decision_id, ticket_id), opts) do
      remove_marker(path)
    end
  end

  defp maybe_resolve(_marker, _decision_id, _ticket_id, _path, _opts), do: :ok

  defp emit_resolution(decision_id, ticket_id, topic, opts) do
    alert_fun = Keyword.get(opts, :alert_fun, &Alerts.emit_system/2)

    alert_fun.(topic <> ".resolved",
      issue: ticket_id,
      message: "Executor Command escalation resolved",
      reason: "Command #{decision_id} was decided.",
      needs_attention: false,
      severity: "info"
    )
  end

  defp emit_alert(topic, message, opts), do: Alerts.emit_system(topic, Keyword.put(opts, :message, message))

  defp identity(decision) do
    with decision_id when is_binary(decision_id) <- present(field(decision, :decision_id)),
         ticket_id when is_binary(ticket_id) <- decision |> field(:ticket) |> field(:identifier) |> present(),
         version when is_integer(version) and version > 0 <- field(decision, :version) do
      {:ok, decision_id, ticket_id, version}
    else
      _missing -> {:error, :decision_identity_missing}
    end
  end

  defp marker_path(decision_id, opts) do
    case Keyword.fetch(opts, :marker_path) do
      {:ok, path} when is_binary(path) -> {:ok, path}
      {:ok, _path} -> {:error, :invalid_marker_path}
      :error -> default_marker_path(decision_id)
    end
  end

  defp default_marker_path(decision_id) do
    with {:ok, root} <- Paths.decision_state_dir() do
      {:ok, Path.join([root, "executor-command-attentions", digest(decision_id) <> ".json"])}
    end
  end

  defp remove_marker(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp digest(decision_id) do
    :sha256
    |> :crypto.hash(decision_id)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present(_value), do: nil

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_value, _key), do: nil
end
