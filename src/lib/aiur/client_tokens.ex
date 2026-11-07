defmodule Aiur.ClientTokens do
  @moduledoc "Hashed, per-client dashboard credentials stored in daemon state."

  alias Aiur.Config.Paths

  @token_bytes 32
  @name ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @digest ~r/\A[0-9a-f]{64}\z/

  # Owned here so identity does not depend on the control-call allowlist, which derives its atoms from this list.
  @categories ~w(read message executor agents tickets config)

  @doc "Permission categories a token can be granted. `trust` is deliberately absent."
  @spec categories() :: [String.t()]
  def categories, do: @categories

  # A token without "categories" is a legacy token: read keeps only `read`, write keeps every category.
  @spec create(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create(name, scope \\ "write", opts \\ []) do
    peer = opts[:peer]
    categories = opts[:categories]

    with :ok <- validate_name(name),
         :ok <- validate_scope(scope),
         :ok <- validate_peer(peer),
         :ok <- validate_categories(categories, scope),
         {:ok, path} <- store_path(),
         {:ok, records} <- read_records(path),
         false <- Enum.any?(records, &(&1["name"] == name)),
         token <- "aiur_" <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false),
         record <- new_record(name, scope, peer, categories, hash(token)),
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
      {:ok, Enum.map(records, &Map.take(&1, ["name", "scope", "peer", "categories", "created_at"]))}
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
  def authenticate(token) do
    with {:ok, %{name: name, scope: scope}} <- authenticate_full(token), do: {:ok, name, scope}
  end

  @spec authenticate_full(term()) :: {:ok, %{name: String.t(), scope: String.t(), peer: String.t() | nil, categories: [String.t()]}} | :error
  def authenticate_full(token) when is_binary(token) do
    with {:ok, path} <- store_path(), {:ok, records} <- read_records(path) do
      find_token(records, hash(token))
    else
      _ -> :error
    end
  end

  def authenticate_full(_), do: :error

  defp find_token(records, token_hash) do
    Enum.find_value(records, :error, fn record ->
      if secure_equal?(record["hash"], token_hash), do: {:ok, effective(record)}
    end)
  end

  defp effective(record) do
    categories = record["categories"] || if(record["scope"] == "read", do: ["read"], else: @categories)
    %{name: record["name"], scope: record["scope"], peer: record["peer"], categories: categories}
  end

  defp new_record(name, scope, peer, categories, digest) do
    base = %{"name" => name, "scope" => scope, "hash" => digest, "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()}
    # An older reader only knows scope, so categories beyond `read` must also store scope "write".
    base = if categories, do: Map.merge(base, %{"categories" => categories, "scope" => if(categories == ["read"], do: "read", else: "write")}), else: base
    if peer, do: Map.put(base, "peer", peer), else: base
  end

  defp validate_peer(nil), do: :ok
  defp validate_peer(peer) when is_binary(peer), do: if(Regex.match?(@name, peer), do: :ok, else: {:error, :invalid_peer})
  defp validate_peer(_), do: {:error, :invalid_peer}

  defp validate_categories(nil, _scope), do: :ok

  defp validate_categories(categories, scope) when is_list(categories) and categories != [] do
    cond do
      not Enum.all?(categories, &(&1 in @categories)) -> {:error, :invalid_categories}
      scope == "read" and categories != ["read"] -> {:error, :scope_conflicts_with_categories}
      true -> :ok
    end
  end

  defp validate_categories(_, _), do: {:error, :invalid_categories}

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
      directory = Path.dirname(path)

      with :ok <- secure_directory(directory),
           :ok <- File.write(temporary, Jason.encode!(records), [:binary, :exclusive]),
           :ok <- File.chmod(temporary, 0o600),
           do: File.rename(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp secure_directory(directory) do
    case File.stat(directory) do
      {:ok, _stat} ->
        :ok

      {:error, :enoent} ->
        create_secure_directory(directory)

      {:error, :eperm} ->
        :ok

      error ->
        error
    end
  end

  defp create_secure_directory(directory) do
    with :ok <- File.mkdir_p(directory), do: chmod_directory(directory)
  end

  defp chmod_directory(directory) do
    case File.chmod(directory, 0o700) do
      :ok -> :ok
      {:error, :eperm} -> :ok
      error -> error
    end
  end

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(@name, name), do: :ok, else: {:error, :invalid_name}
  end

  defp validate_name(_), do: {:error, :invalid_name}

  defp valid_record?(%{"name" => name, "scope" => scope, "hash" => digest, "created_at" => created_at} = record) do
    validate_name(name) == :ok and validate_scope(scope) == :ok and is_binary(created_at) and is_binary(digest) and Regex.match?(@digest, digest) and
      validate_peer(record["peer"]) == :ok and validate_categories(record["categories"], scope) == :ok
  end

  defp valid_record?(_), do: false

  defp validate_scope(scope) when scope in ["read", "write"], do: :ok
  defp validate_scope(_), do: {:error, :invalid_scope}

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_, _), do: false
end
