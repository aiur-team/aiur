defmodule Aiur.Accounts.Shims.Claude do
  @moduledoc "Claude Code profile adapter."
  @behaviour Aiur.Accounts.Shim

  @impl true
  def profile_env(dir), do: [{"CLAUDE_CONFIG_DIR", dir}]

  @impl true
  def shared_paths, do: ["settings.json", "CLAUDE.md", "plugins", "skills", "projects/*/memory"]

  @impl true
  def never_shared, do: [".claude.json", "projects/*", "sessions/", "history.jsonl", "remote-settings.json", "policy-limits.json"]

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
    credentials = if is_nil(dir), do: Aiur.Claude.UsageApi.default_credentials_path(), else: Path.join(dir, ".credentials.json")
    Aiur.Claude.UsageApi.fetch_with_metadata(credentials_path: credentials, cache_key: usage_cache_key(dir))
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
