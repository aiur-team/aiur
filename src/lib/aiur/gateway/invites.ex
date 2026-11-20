defmodule Aiur.Gateway.Invites do
  @moduledoc """
  One-time enrolment invites (`gateway-invites.json` in the decision state dir, mode 0600).

  Only the secret's sha256 is stored. `redeem/5` validates, runs the caller's writes and burns the invite
  in one locked step, so two concurrent joins with one code cannot both succeed and a refusal leaves
  the file untouched. Used invites stay 24 hours for the audit trail, then drop on the next write.
  """

  alias Aiur.Config.Paths

  @default_ttl 600
  @max_ttl 86_400
  @keep 86_400

  @type error :: :invalid_invite | :expired | :used | term()

  @spec default_ttl() :: pos_integer()
  def default_ttl, do: @default_ttl

  @spec max_ttl() :: pos_integer()
  def max_ttl, do: @max_ttl

  @doc "Stores a new invite for `grants`; the plain secret is returned once and never kept."
  @spec create([String.t()], pos_integer(), integer()) :: {:ok, %{id: String.t(), secret: String.t(), exp: integer()}} | {:error, term()}
  def create(grants, ttl \\ @default_ttl, now \\ System.os_time(:second)) when is_list(grants) and is_integer(ttl) do
    if ttl < 1 or ttl > @max_ttl, do: {:error, :invalid_ttl}, else: store_new(grants, ttl, now)
  end

  defp store_new(grants, ttl, now) do
    id = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    secret = "aiur_inv_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    record = %{"id" => id, "secret_sha256" => hash(secret), "exp" => now + ttl, "grants" => grants, "created_at" => now, "used_at" => nil}

    with :ok <- update(now, fn records -> {:ok, [record | records], nil} end), do: {:ok, %{id: id, secret: secret, exp: now + ttl}}
  end

  @doc """
  Validates `id`/`secret`, calls `fun.(grants)` and burns the invite only when it returns `{:ok, result}`.

  Order of refusals: unknown id or wrong secret (`:invalid_invite`, indistinguishable), `:expired`, `:used`.
  """
  @spec redeem(String.t(), String.t(), integer(), (list() -> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, error()}
  def redeem(id, secret, now \\ System.os_time(:second), fun) when is_binary(id) and is_binary(secret) do
    lock(fn ->
      with {:ok, records} <- read(),
           {:ok, record} <- find(records, id, secret),
           :ok <- usable(record, now),
           {:ok, result} <- fun.(record["grants"]) do
        burn_all(records, id, now, result)
      end
    end)
  end

  # A burn that fails after the caller's writes leaves the caller to undo them.
  defp burn_all(records, id, now, result) do
    case write(prune(Enum.map(records, &burn(&1, id, now)), now)) do
      :ok -> {:ok, result}
      {:error, _reason} -> {:error, {:burn_failed, result}}
    end
  end

  @doc "True when at least one invite is unused and unexpired; hello reports this as `enrollment: open`."
  @spec open?(integer()) :: boolean()
  def open?(now \\ System.os_time(:second)) do
    case read() do
      {:ok, records} -> Enum.any?(records, &(usable(&1, now) == :ok))
      {:error, _reason} -> false
    end
  end

  @spec list() :: {:ok, [map()]} | {:error, term()}
  def list, do: with({:ok, records} <- read(), do: {:ok, Enum.map(records, &Map.delete(&1, "secret_sha256"))})

  @spec revoke(String.t()) :: :ok | {:error, term()}
  def revoke(id) do
    update(System.os_time(:second), fn records ->
      if Enum.any?(records, &(&1["id"] == id)), do: {:ok, Enum.reject(records, &(&1["id"] == id)), nil}, else: {:error, :not_found}
    end)
  end

  defp find(records, id, secret) do
    digest = hash(secret)

    case Enum.find(records, &(&1["id"] == id)) do
      %{"secret_sha256" => stored} = record -> if Plug.Crypto.secure_compare(stored, digest), do: {:ok, record}, else: {:error, :invalid_invite}
      nil -> {:error, :invalid_invite}
    end
  end

  defp usable(%{"used_at" => used}, _now) when not is_nil(used), do: {:error, :used}
  defp usable(%{"exp" => exp}, now), do: if(now >= exp, do: {:error, :expired}, else: :ok)

  defp burn(%{"id" => id} = record, id, now), do: %{record | "used_at" => now}
  defp burn(record, _id, _now), do: record

  defp prune(records, now), do: Enum.reject(records, &(is_integer(&1["used_at"]) and now - &1["used_at"] > @keep))

  defp update(now, fun) do
    lock(fn ->
      with {:ok, records} <- read(),
           {:ok, new, _} <- fun.(records),
           do: write(prune(new, now))
    end)
  end

  defp lock(fun), do: :global.trans({{__MODULE__, :store}, self()}, fun)

  defp path do
    case Application.get_env(:aiur, :gateway_invites_path) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> with {:ok, root} <- Paths.decision_state_dir(), do: {:ok, Path.join(root, "gateway-invites.json")}
    end
  end

  defp read do
    with {:ok, path} <- path() do
      case File.read(path) do
        {:ok, text} -> decode(text)
        {:error, :enoent} -> {:ok, []}
        {:error, reason} -> {:error, {:store_unavailable, reason}}
      end
    end
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, records} when is_list(records) -> {:ok, records}
      _ -> {:error, :corrupt_store}
    end
  end

  defp write(records) do
    with {:ok, path} <- path(), :ok <- File.mkdir_p(Path.dirname(path)), do: Aiur.Fs.atomic_write(path, Jason.encode!(records), mode: 0o600)
  end

  defp hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
end
