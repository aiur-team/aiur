defmodule Aiur.Accounts.Shims.Codex do
  @moduledoc "Codex CLI profile adapter."
  @behaviour Aiur.Accounts.Shim

  @impl true
  def profile_env(dir), do: [{"CODEX_HOME", dir}]

  @impl true
  def shared_paths, do: ["config.toml", "skills"]

  @impl true
  def never_shared, do: ["auth.json", "sessions", "state_*.sqlite"]

  @impl true
  def profile_root, do: Path.join(System.get_env("HOME") || Path.expand("~"), ".codex")

  @impl true
  def login_command(dir), do: {"env", ["CODEX_HOME=" <> dir, "codex"]}

  @impl true
  def identity(dir) do
    path = Path.join(dir || profile_root(), "auth.json")

    with {:ok, contents} <- File.read(path),
         {:ok, data} when is_map(data) <- Jason.decode(contents),
         %{} = auth <- Map.get(data, "tokens", data) do
      metadata = auth |> Map.get("id_token") |> decode_jwt_payload()
      identity_fields(auth, metadata)
    else
      _ -> %{}
    end
  end

  defp identity_fields(auth, metadata) do
    profile = Map.get(metadata, "https://api.openai.com/profile", %{})
    auth_claims = Map.get(metadata, "https://api.openai.com/auth", %{})

    account_id =
      Map.get(auth, "account_id") || Map.get(auth_claims, "chatgpt_account_id") || Map.get(profile, "chatgpt_account_id") ||
        Map.get(metadata, "chatgpt_account_id")

    email = Map.get(profile, "email") || Map.get(metadata, "email")

    if account_id || email do
      %{"account_id" => account_id, "email" => email}
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    else
      %{}
    end
  end

  @impl true
  def usage(dir) do
    case Aiur.CodexProber.fetch_limits("codex", codex_home: dir || profile_root()) do
      {:ok, limits} -> {:ok, limits}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_jwt_payload(token) when is_binary(token) do
    with [_header, payload | _] <- String.split(token, "."),
         normalized <- String.replace(payload, "-", "+") |> String.replace("_", "/"),
         {:ok, json} <- Base.decode64(pad_base64(normalized)),
         {:ok, data} when is_map(data) <- Jason.decode(json) do
      data
    else
      _ -> %{}
    end
  end

  defp decode_jwt_payload(_), do: %{}
  defp pad_base64(value), do: value <> String.duplicate("=", rem(4 - rem(byte_size(value), 4), 4))
end
