defmodule Aiur.Opencode.SessionWriterRegistry do
  @moduledoc """
  Per-identifier registry for `Aiur.Opencode.SessionWriter` processes.
  One writer per active agent — `ensure/2` is idempotent and is the only
  public entrypoint, so v2 background population can spawn writers for
  every active agent at boot without touching pane-open code.

  Aiur tracks every session it creates (per-identifier sessions + the
  warm placeholder) so shutdown can `DELETE /session/<id>` for each.
  The session id lives in the registry value alongside the writer pid.
  """

  alias Aiur.Opencode.{ApiClient, Config, PersistentPane, Protocol, SessionSupervisor, SessionWriter, TokenRegistry}

  @registry __MODULE__.Registry

  @doc """
  Idempotently ensure a `SessionWriter` is running for `identifier` and
  an opencode session exists for it.

  If a writer is already alive, returns its `{session_id, pid}`.
  Otherwise: `POST /session` with `model: {providerID: "aiur", id: "issue-<X>"}`
  and `directory: workspace_for(identifier)`, then start the writer.
  """
  @spec ensure(String.t(), String.t()) ::
          {:ok, %{session_id: String.t(), writer_pid: pid()}} | {:error, term()}
  def ensure(identifier, base_url) when is_binary(identifier) and is_binary(base_url) do
    case lookup(identifier) do
      {:ok, _} = found ->
        found

      :not_found ->
        with {:ok, session_id} <- create_session(identifier, base_url),
             {:ok, pid} <- start_writer(identifier, session_id, base_url) do
          {:ok, %{session_id: session_id, writer_pid: pid}}
        end
    end
  end

  @doc """
  Look up the session + writer for `identifier`, or return `:not_found`.
  Returns the legacy `%{session_id, writer_pid}` shape so existing callers
  (`PaneManager`, `ChatCompletions`) keep working unchanged.
  """
  @spec lookup(String.t()) :: {:ok, %{session_id: String.t(), writer_pid: pid()}} | :not_found
  def lookup(identifier) when is_binary(identifier) do
    case Registry.lookup(@registry, identifier) do
      [{pid, %PersistentPane{} = pane}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, %{session_id: pane.session_id, writer_pid: pid}}
        else
          :not_found
        end

      _ ->
        :not_found
    end
  end

  @doc """
  Look up the full `PersistentPane` struct for `identifier`. PaneManager
  and AttachQueue use this to read pane_id and status.
  """
  @spec get_pane(String.t()) :: {:ok, PersistentPane.t()} | :not_found
  def get_pane(identifier) when is_binary(identifier) do
    case Registry.lookup(@registry, identifier) do
      [{pid, %PersistentPane{} = pane}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pane}, else: :not_found

      _ ->
        :not_found
    end
  end

  @doc """
  Update the `PersistentPane` value for `identifier` via `fun`. The
  caller passes a function `(PersistentPane.t() -> PersistentPane.t())`
  that returns the new struct. Returns `{:ok, new_pane}` or `:not_found`.

  Delegates through `SessionWriter.update_pane/2` because Registry
  values can only be mutated from inside the owner process.
  """
  @spec update_pane(String.t(), (PersistentPane.t() -> PersistentPane.t())) ::
          {:ok, PersistentPane.t()} | :not_found
  def update_pane(identifier, fun) when is_binary(identifier) and is_function(fun, 1) do
    case Registry.lookup(@registry, identifier) do
      [{pid, %PersistentPane{}}] when is_pid(pid) ->
        if Process.alive?(pid) do
          SessionWriter.update_pane(pid, fun)
        else
          :not_found
        end

      _ ->
        :not_found
    end
  end

  @doc """
  Enumerate every (identifier, session_id, writer_pid) tracked here.
  Used by `Aiur.Shutdown.shutdown/2` to walk the registry and DELETE
  each session before halting.
  """
  @spec all() :: [%{identifier: String.t(), session_id: String.t(), writer_pid: pid()}]
  def all do
    Registry.select(@registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(fn {identifier, pid, %PersistentPane{} = pane} ->
      %{identifier: identifier, session_id: pane.session_id, writer_pid: pid}
    end)
  end

  @doc """
  Synchronously walk the registry: stop each writer and DELETE its
  opencode session via `ApiClient.delete_session/2`. Idempotent — both
  `Aiur.Shutdown.shutdown/2` and `Aiur.Application.stop/1` may call this.

  Best-effort: individual failures are logged and skipped; the call
  returns when every entry has been attempted or `timeout_ms` elapses.
  """
  @spec delete_all(non_neg_integer()) :: :ok
  def delete_all(timeout_ms \\ 5_000) when is_integer(timeout_ms) and timeout_ms >= 0 do
    entries = all()

    if entries == [] do
      :ok
    else
      base_url = current_base_url(entries)
      deadline = System.monotonic_time(:millisecond) + timeout_ms

      Enum.each(entries, fn %{identifier: identifier, session_id: session_id, writer_pid: pid} ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        if remaining > 0 do
          _ = maybe_delete_session(base_url, session_id)
          _ = DynamicSupervisor.terminate_child(SessionSupervisor, pid)
          _ = Registry.unregister(@registry, identifier)
        end
      end)

      :ok
    end
  end

  # --- internals ----------------------------------------------------------

  defp create_session(identifier, base_url) do
    safe_id = Config.safe_identifier(identifier)
    directory = workspace_for(identifier)
    _ = File.mkdir_p(directory)

    # Regenerate opencode.json so stale fields (e.g. `aiur_metadata`
    # from older aiur versions) don't trip opencode's strict schema
    # validation. We do this *before* POST /session because opencode
    # reads the workspace's config the moment a session is created.
    :ok = regenerate_workspace_config(directory, identifier)

    opts = [
      model: %{providerID: "aiur", id: "issue-#{safe_id}"},
      directory: directory
    ]

    case ApiClient.create_session(base_url, identifier, opts) do
      {:ok, %{"id" => id}} when is_binary(id) -> {:ok, id}
      {:ok, %{id: id}} when is_binary(id) -> {:ok, id}
      {:ok, %{"session" => %{"id" => id}}} when is_binary(id) -> {:ok, id}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, _reason} = err -> err
    end
  end

  defp regenerate_workspace_config(workspace, identifier) do
    bridge_url = "http://#{Config.bridge_host()}:#{Config.bridge_port()}"
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    config =
      Protocol.opencode_json(%{
        bridge_url: bridge_url,
        bridge_token: token,
        identifier: identifier,
        model_prefix: Config.model_prefix(),
        opencode_os_pid: nil
      })

    tui = Protocol.tui_json()
    theme = Protocol.aiur_theme_json()

    with :ok <- File.mkdir_p(Path.join(workspace, ".opencode/themes")),
         :ok <-
           File.write(Path.join(workspace, "opencode.json"), Jason.encode!(config, pretty: true)),
         :ok <- File.write(Path.join(workspace, "tui.json"), Jason.encode!(tui, pretty: true)),
         :ok <-
           File.write(
             Path.join(workspace, ".opencode/themes/aiur.json"),
             Jason.encode!(theme, pretty: true)
           ) do
      TokenRegistry.put(token, Config.safe_identifier(identifier))
      :ok
    else
      {:error, reason} ->
        require Logger

        Logger.warning(
          "opencode_session_writer_registry workspace_config_failed identifier=#{identifier} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp start_writer(identifier, session_id, base_url) do
    spec = %{
      id: {SessionWriter, identifier},
      start:
        {SessionWriter, :start_link,
         [%{identifier: identifier, session_id: session_id, base_url: base_url}]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(SessionSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} = err -> err
    end
  end

  defp workspace_for(identifier) do
    Aiur.Config.workspace_root()
    |> Path.expand()
    |> Path.join(Aiur.Opencode.Config.safe_identifier(identifier))
  end

  defp current_base_url(entries) do
    case entries do
      [%{writer_pid: pid} | _] when is_pid(pid) ->
        try do
          %SessionWriter{} = state = :sys.get_state(pid, 200)
          state.base_url
        catch
          _, _ -> nil
        end

      _ ->
        nil
    end
  end

  defp maybe_delete_session(nil, _session_id), do: :ok
  defp maybe_delete_session(base_url, session_id), do: ApiClient.delete_session(base_url, session_id)
end
