defmodule Aiur.ClientTokens do
  @moduledoc "Hashed, per-client dashboard credentials stored in daemon state."

  alias Aiur.Config.Paths

  @token_bytes 32
  @name ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @digest ~r/\A[0-9a-f]{64}\z/

  @spec create(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create(name, scope \\ "write") do
    with :ok <- validate_name(name),
         :ok <- validate_scope(scope),
         {:ok, path} <- store_path(),
         {:ok, records} <- read_records(path),
         false <- Enum.any?(records, &(&1["name"] == name)),
         token <- "aiur_" <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false),
         record <- %{"name" => name, "scope" => scope, "hash" => hash(token), "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()},
         :ok <- write_records(path, [record | records]) do
      {:ok, token}
    else
      true -> {:error, :name_exists}
      error -> error
    end
  end

  @spec list() :: {:ok, [map()]} | {:error, term()}
  def list do
    with {:ok, path} <- store_path(), {:ok, records} <- read_records(path) do
      {:ok, Enum.map(records, &Map.take(&1, ["name", "scope", "created_at"]))}
    end
  end

  @spec revoke(String.t()) :: :ok | {:error, term()}
  def revoke(name) do
    with :ok <- validate_name(name),
         {:ok, path} <- store_path(),
         {:ok, records} <- read_records(path),
         true <- Enum.any?(records, &(&1["name"] == name)),
         :ok <- write_records(path, Enum.reject(records, &(&1["name"] == name))) do
      :ok
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  @spec authenticate(term()) :: {:ok, String.t(), String.t()} | :error
  def authenticate(token) when is_binary(token) do
    with {:ok, path} <- store_path(), {:ok, records} <- read_records(path) do
      authenticate_records(records, token)
    else
      _ -> :error
    end
  end

  def authenticate(_), do: :error

  defp authenticate_records(records, token) do
    token_hash = hash(token)

    Enum.find_value(records, :error, fn record ->
      if secure_equal?(record["hash"], token_hash), do: {:ok, record["name"], record["scope"]}
    end)
  end

  defp store_path do
    case Application.get_env(:aiur, :client_tokens_path) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> with {:ok, root} <- Paths.decision_state_dir(), do: {:ok, Path.join(root, "client-tokens.json")}
    end
  end

  defp read_records(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, records} when is_list(records) ->
            validate_records(records)

          _ ->
            {:error, :corrupt_store}
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:store_unavailable, reason}}
    end
  end

  defp validate_records(records) do
    if Enum.all?(records, &valid_record?/1), do: {:ok, records}, else: {:error, :corrupt_store}
  end

  defp write_records(path, records) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(temporary, Jason.encode!(records), [:binary, :exclusive]),
           :ok <- File.chmod(temporary, 0o600),
           do: File.rename(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(@name, name), do: :ok, else: {:error, :invalid_name}
  end

  defp validate_name(_), do: {:error, :invalid_name}

  defp valid_record?(%{"name" => name, "scope" => scope, "hash" => digest, "created_at" => created_at}) do
    validate_name(name) == :ok and validate_scope(scope) == :ok and is_binary(created_at) and is_binary(digest) and Regex.match?(@digest, digest)
  end

  defp valid_record?(_), do: false

  defp validate_scope(scope) when scope in ["read", "write"], do: :ok
  defp validate_scope(_), do: {:error, :invalid_scope}

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_, _), do: false
end
