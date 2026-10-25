defmodule Aiur.IssueLog.Writers do
  @moduledoc false

  require Logger

  alias Aiur.IssueLog.Paths
  alias Aiur.TrackerIdentity

  @supervisor Aiur.IssueLog.Supervisor

  @spec attach_writer(String.t(), String.t(), String.t(), String.t(), term()) :: :ok
  def attach_writer(identifier, path, event_path, transcript_path, key) do
    case ensure_writer(identifier, path, event_path, transcript_path, key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("IssueLog.attach(#{identifier}) failed: #{inspect(reason)}")
        :ok
    end
  end

  defp ensure_writer(identifier, path, event_path, transcript_path, key) do
    case Registry.lookup(Aiur.IssueLog.Registry, key) do
      [] ->
        start_writer(identifier, path, event_path, transcript_path, key)

      [{pid, _}] ->
        if writer_path(pid) == path do
          :ok
        else
          replace_writer(identifier, pid, path, event_path, transcript_path, key)
        end
    end
  end

  defp replace_writer(identifier, pid, path, event_path, transcript_path, key) do
    case DynamicSupervisor.terminate_child(@supervisor, pid) do
      :ok -> start_writer(identifier, path, event_path, transcript_path, key)
      {:error, :not_found} -> start_writer(identifier, path, event_path, transcript_path, key)
    end
  end

  defp start_writer(identifier, path, event_path, transcript_path, key) do
    DynamicSupervisor.start_child(
      @supervisor,
      {Aiur.IssueLog, identifier: identifier, path: path, event_path: event_path, transcript_path: transcript_path, writer_key: key}
    )
    |> normalize_start_result()
  end

  defp normalize_start_result({:ok, _pid}), do: :ok
  defp normalize_start_result({:error, {:already_started, _pid}}), do: :ok
  defp normalize_start_result({:error, reason}), do: {:error, reason}

  @spec writer_for_path(String.t(), String.t(), term()) :: [{pid(), term()}]
  def writer_for_path(_identifier, path, key) do
    case Registry.lookup(Aiur.IssueLog.Registry, key) do
      [{pid, _}] = writer -> if writer_path(pid) == path, do: writer, else: []
      _ -> []
    end
  end

  defp writer_path(pid) do
    GenServer.call(pid, :path, 1_000)
  catch
    :exit, _ -> nil
  end

  @spec writer_key(String.t() | TrackerIdentity.t()) :: tuple()
  def writer_key(identifier) when is_binary(identifier),
    do: {:issue_log, Paths.configured_repository_scope(), identifier}

  def writer_key(%TrackerIdentity{} = identity) do
    {:github, owner, repository, _provider_id} = TrackerIdentity.github_key(identity)
    {:issue_log, Paths.repository_scope(owner, repository), identity.identifier}
  end

  @spec via(term()) :: {:via, module(), {atom(), term()}}
  def via(key), do: {:via, Registry, {Aiur.IssueLog.Registry, key}}
end
