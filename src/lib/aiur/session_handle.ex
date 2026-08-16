defmodule Aiur.SessionHandle do
  @moduledoc """
  Durable per-issue coding-agent session handle, so an in-flight issue can
  resume its prior agent thread after an aiur restart instead of cold-starting
  a brand-new conversation that re-discovers the work (issue #378).

  The handle is a small JSON sidecar written via the crash-safe
  `Aiur.JsonStore`. It lives in the shared per-issue state directory
  (`Aiur.Config.Paths.log_root_dir/0`, keyed `<repo>.<id>.session.json`) — the
  same place `Aiur.Events.SubscriptionStore` keeps its per-issue state — rather
  than inside the per-issue git workspace. That location is deliberate: it
  survives a workspace reclone, and the backend's on-disk rollout it points at
  (codex keeps thread rollouts under `~/.codex/sessions/**`) is likewise
  host-local and reclone-surviving, so the handle and the thread it names stay
  paired.

  `load/3` is the safety gate: it returns the handle only when it is for the
  same backend the runner is about to start AND was written on this host (a
  codex rollout cannot be loaded on a different machine). A missing, corrupt,
  forward-versioned, backend-mismatched, host-mismatched, or thread-id-less
  handle returns `:none`, and the caller degrades to a clean start. Nothing
  here ever raises on a bad handle — resume must never be able to strand an
  issue that would otherwise cold-start fine.
  """

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @schema_version 1

  @type attrs :: %{
          required(:backend) => String.t(),
          required(:thread_id) => String.t()
        }

  @type handle :: %{
          backend: String.t(),
          thread_id: String.t(),
          hostname: String.t(),
          updated_at: String.t() | nil
        }

  @doc """
  Persist the session handle for `identifier`. Overwrites any prior handle.
  `opts` accepts `:dir` (defaults to the shared state dir) and `:hostname`
  (defaults to this host) — both injectable for tests.
  """
  @spec save(String.t(), attrs(), keyword()) :: :ok
  def save(identifier, %{backend: backend, thread_id: thread_id}, opts \\ [])
      when is_binary(backend) and is_binary(thread_id) do
    payload = %{
      "schema_version" => @schema_version,
      "backend" => backend,
      "thread_id" => thread_id,
      "hostname" => hostname(opts),
      "updated_at" => timestamp()
    }

    JsonStore.write!(path_for(identifier, opts), payload)
  end

  @doc """
  Load the resumable handle for `identifier` when it is safe to resume:
  same backend (`expected_backend`) and same host. Returns `{:ok, handle}` or
  `:none`. Never raises — any unreadable/invalid/foreign handle is `:none`.
  """
  @spec load(String.t(), String.t(), keyword()) :: {:ok, handle()} | :none
  def load(identifier, expected_backend, opts \\ []) when is_binary(expected_backend) do
    case JsonStore.read(path_for(identifier, opts)) do
      {:ok, nil} ->
        :none

      {:ok, raw} when is_map(raw) ->
        validate(raw, expected_backend, hostname(opts), identifier)

      {:ok, _other} ->
        :none

      {:error, reason} ->
        Logger.warning("SessionHandle(#{identifier}) unreadable handle, treating as clean start: #{inspect(reason)}")
        :none
    end
  end

  @doc "Remove the handle for `identifier`. Idempotent."
  @spec clear(String.t(), keyword()) :: :ok
  def clear(identifier, opts \\ []) do
    _ = File.rm(path_for(identifier, opts))
    :ok
  end

  @doc """
  Absolute path of the handle file for `identifier`. Exposed for tests.

  `opts` accepts `:dir` (defaults to the shared state dir), `:hostname`
  (defaults to this host) and `:repo_name` (defaults to the ambient
  `Paths.repo_name/0`). The `:repo_name` override exists so a test can pin the
  filename independent of the shared workflow config — `repo_name/0` reads the
  current tracker identity, which a concurrent async test can rewrite mid-run
  and flip the path under a save-then-load pair (#1920).
  """
  @spec path_for(String.t(), keyword()) :: Path.t()
  def path_for(identifier, opts \\ []) do
    dir = Keyword.get(opts, :dir) || Paths.log_root_dir()
    repo_name = Keyword.get(opts, :repo_name) || Paths.repo_name()
    Path.join(dir, "#{repo_name}.#{Paths.sanitize(to_string(identifier))}.session.json")
  end

  defp validate(raw, expected_backend, host, identifier) do
    with %{"schema_version" => @schema_version} <- raw,
         %{"backend" => ^expected_backend} <- raw,
         %{"hostname" => ^host} <- raw,
         %{"thread_id" => thread_id} when is_binary(thread_id) <- raw do
      {:ok,
       %{
         backend: expected_backend,
         thread_id: thread_id,
         hostname: host,
         updated_at: Map.get(raw, "updated_at")
       }}
    else
      _ ->
        Logger.debug("SessionHandle(#{identifier}) not resumable (stale/foreign/incompatible); clean start")
        :none
    end
  end

  defp hostname(opts) do
    case Keyword.get(opts, :hostname) do
      host when is_binary(host) ->
        host

      _ ->
        {:ok, name} = :inet.gethostname()
        to_string(name)
    end
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.to_iso8601()
  rescue
    _ -> nil
  end
end
