defmodule Aiur.Gateway.StatusCache do
  @moduledoc "Last good answer per registry entry, `~/.aiur/remote-state/<name>.json` (mode 0600). A missing or corrupt file reads as `:none`."

  @spec dir() :: Path.t()
  def dir, do: Application.get_env(:aiur, :remote_state_dir, Path.join([System.get_env("HOME") || Path.expand("~"), ".aiur", "remote-state"]))

  @spec write(String.t(), map()) :: :ok | {:error, term()}
  def write(name, body) do
    with {:ok, path} <- path(name),
         :ok <- File.mkdir_p(dir()) do
      Aiur.Fs.atomic_write(path, Jason.encode!(body), mode: 0o600)
    end
  end

  @doc "`{:ok, %{observed_at: DateTime, agents: n, gateway_id: _, gateway_label: _, build: _}}` or `:none`."
  @spec read(String.t()) :: {:ok, map()} | :none
  def read(name) do
    with {:ok, path} <- path(name),
         {:ok, raw} <- File.read(path),
         {:ok, %{"observed_at" => at, "agents" => n} = body} when is_integer(n) and n >= 0 <- Jason.decode(raw),
         {:ok, observed_at, _offset} <- DateTime.from_iso8601(at) do
      {:ok, %{observed_at: observed_at, agents: n, gateway_id: body["gateway_id"], gateway_label: body["gateway_label"], build: body["build"]}}
    else
      _ -> :none
    end
  end

  defp path(name) do
    if is_binary(name) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, name), do: {:ok, Path.join(dir(), name <> ".json")}, else: {:error, :invalid_name}
  end
end
