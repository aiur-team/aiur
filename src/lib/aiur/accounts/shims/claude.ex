defmodule Aiur.Accounts.Shims.Claude do
  @moduledoc "Claude Code profile adapter."
  @behaviour Aiur.Accounts.Shim

  alias Aiur.Claude.{RemoteControl, UsageApi}

  @impl true
  def profile_env(dir), do: [{"CLAUDE_CONFIG_DIR", dir}]

  @impl true
  def shared_paths, do: ["settings.json", "CLAUDE.md", "plugins", "skills", "projects/*/memory"]

  @impl true
  def never_shared, do: [".claude.json", "projects/*", "sessions/", "history.jsonl", "remote-settings.json", "policy-limits.json"]

  @impl true
  def profile_root, do: Path.join([System.get_env("HOME") || Path.expand("~"), ".claude"])

  @impl true
  def login_command(dir), do: {"env", ["CLAUDE_CONFIG_DIR=" <> dir, "claude"]}

  @impl true
  def identity(dir) do
    path =
      if is_nil(dir),
        do: Path.join(System.get_env("HOME") || Path.expand("~"), ".claude.json"),
        else: Path.join(dir, ".claude.json")

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, data} -> identity_fields(data)
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  @impl true
  def usage(dir) do
    credentials = if is_nil(dir), do: UsageApi.default_credentials_path(), else: Path.join(dir, ".credentials.json")
    UsageApi.fetch_with_metadata(credentials_path: credentials, cache_key: usage_cache_key(dir))
  end

  @impl true
  def session_artifacts(dir, session_id, cwd) do
    project = Path.join([dir, "projects", RemoteControl.workspace_slug(cwd)])
    short_id = String.slice(session_id, 0, 8)

    explicit = [
      Path.join(project, session_id <> ".jsonl"),
      Path.join(project, session_id),
      Path.join([dir, "file-history", session_id]),
      Path.join([dir, "session-env", session_id]),
      Path.join([dir, "image-cache", session_id]),
      Path.join([dir, "jobs", short_id]),
      Path.join([dir, "tasks", "session-" <> short_id]),
      Path.join([dir, "teams", "session-" <> short_id])
    ]

    broad =
      Path.wildcard(Path.join(dir, "**/*"), match_dot: true)
      |> Enum.filter(fn path ->
        relative = Path.relative_to(path, dir)
        length(Path.split(relative)) <= 3 and String.contains?(Path.basename(path), session_id)
      end)

    (explicit ++ broad)
    |> Enum.uniq()
    |> Enum.sort_by(&length(Path.split(&1)))
    |> Enum.reduce([], fn path, parents ->
      if Enum.any?(parents, &String.starts_with?(path, &1 <> "/")), do: parents, else: [path | parents]
    end)
    |> Enum.filter(&File.exists?/1)
    |> Enum.reject(fn path ->
      case File.lstat(path) do
        {:ok, %{type: :symlink}} -> true
        _ -> false
      end
    end)
  end

  @doc false
  @spec usage_cache_key(Path.t() | nil) :: {module(), Path.t() | nil}
  def usage_cache_key(dir), do: {__MODULE__, dir}

  defp identity_fields(data) when is_map(data) do
    account = Map.get(data, "oauthAccount", %{})

    %{
      "email" => data["email"] || account["emailAddress"],
      "organization" => data["organization"] || account["organizationName"],
      "seatTier" => data["seatTier"] || account["subscriptionType"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp identity_fields(_invalid_json_shape), do: %{}
end
