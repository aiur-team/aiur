defmodule Aiur.Gateway.Registry do
  @moduledoc """
  The gateway registry file (`~/.aiur/remote-instances.yaml`, schema S2) as the receiver reads it.

  `get/0` parses and validates the file, cached by path and file identity (mtime, size, inode) like
  `Aiur.Machine.Settings.get/0`, so a hand edit applies on the next call. A file that fails validation
  keeps the last good value in force (`last_error` names the failing key); with no last good value
  `get/0` returns the error. A missing file is an empty registry.

  `write/2` is the only writer. It is called by local CLI and dashboard code only; no allowlisted
  control call may reach it (`no_remote_writer_test.exs` walks the call graph). Comments in the file
  are not preserved. The file is written in the block style the launcher's awk parser reads.
  """

  alias Aiur.ControlCall.Audit

  require Logger

  @categories Aiur.ClientTokens.categories()
  @secret_keys ~w(token secret password)
  @fields ~w(url token_file token_env gateway_id label tls_pin_sha256 allows)
  @name ~r/^[A-Za-z0-9._-]+$/

  @type peer :: %{name: String.t(), gateway_id: String.t() | nil, label: String.t() | nil, categories: [String.t()], credentials: [String.t()]}
  @type view :: %{peers: %{String.t() => peer()}, instances: map(), last_error: term() | nil}
  @type error :: {:invalid, String.t(), String.t()} | {:unreadable, term()}

  @spec path() :: Path.t()
  def path, do: Application.get_env(:aiur, :gateway_registry_path, Path.join([System.get_env("HOME") || Path.expand("~"), ".aiur", "remote-instances.yaml"]))

  @doc "Grantable categories, in code order. `trust` is deliberately not one."
  @spec categories() :: [String.t()]
  def categories, do: @categories

  @spec get() :: {:ok, view()} | {:error, error()}
  def get do
    key = {__MODULE__, path()}
    identity = identity()

    case :persistent_term.get(key, nil) do
      {^identity, result} -> result
      cached -> refresh(key, identity, cached)
    end
  end

  defp refresh(key, identity, cached) do
    result = fallback(load(), cached)
    audit_edit(cached, result)
    :persistent_term.put(key, {identity, result})
    log_error(result)
    result
  end

  defp fallback({:error, reason}, {_, {:ok, view}}), do: {:ok, %{view | last_error: reason}}
  defp fallback(result, _cached), do: result

  defp log_error({:ok, %{last_error: nil}}), do: :ok
  defp log_error({:ok, %{last_error: reason}}), do: Logger.warning("gateway registry rejected, keeping the last good one: #{inspect(reason)}")
  defp log_error({:error, reason}), do: Logger.warning("gateway registry rejected: #{inspect(reason)}")

  defp audit_edit({_, {:ok, old}}, {:ok, %{last_error: nil} = new}) do
    for {name, peer} <- new.peers, grants(old.peers[name]) != grants(peer) do
      Audit.append(%{at: now(), event: "file_edit_detected", actor: "unknown_local_editor", peer: peer.gateway_id, name: name, categories: peer.categories})
    end

    :ok
  end

  defp audit_edit(_cached, _result), do: :ok
  defp grants(nil), do: nil
  defp grants(peer), do: {peer.categories, peer.credentials}

  defp identity do
    case File.stat(path(), time: :posix) do
      {:ok, stat} -> {stat.mtime, stat.size, stat.inode}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load() :: {:ok, view()} | {:error, error()}
  def load do
    case File.read(path()) do
      {:ok, text} -> with {:ok, raw} <- parse(text), do: validate(raw)
      {:error, :enoent} -> validate(%{"version" => 1, "instances" => %{}})
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp parse(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, {:invalid, "instances", "expected a map"}}
      {:error, _reason} -> {:error, {:invalid, "file", "not valid YAML"}}
    end
  end

  @doc "Validates a parsed registry. The error names the offending key."
  @spec validate(map()) :: {:ok, view()} | {:error, error()}
  def validate(raw) do
    instances = Map.get(raw, "instances") || %{}

    with :ok <- check(Map.get(raw, "version", 1) == 1, "version", "must be 1"),
         :ok <- check(is_map(instances), "instances", "expected a map"),
         {:ok, peers} <- peers(instances),
         :ok <- unique_ids(peers) do
      {:ok, %{peers: peers, instances: instances, last_error: nil}}
    end
  end

  defp peers(instances) do
    Enum.reduce_while(instances, {:ok, %{}}, fn {name, entry}, {:ok, acc} ->
      case peer(to_string(name), entry) do
        {:ok, peer} -> {:cont, {:ok, Map.put(acc, peer.name, peer)}}
        error -> {:halt, error}
      end
    end)
  end

  defp peer(name, entry) when is_map(entry) do
    with :ok <- check(Regex.match?(@name, name) and name != "all", "instances.#{name}", "invalid instance name"),
         :ok <- fields(name, entry),
         {:ok, allows} <- allows(name, Map.get(entry, "allows")) do
      {:ok, %{name: name, gateway_id: entry["gateway_id"], label: entry["label"], categories: allows.categories, credentials: allows.credentials}}
    end
  end

  defp peer(name, _entry), do: {:error, {:invalid, "instances.#{name}", "expected a map"}}

  defp fields(name, entry) do
    Enum.find_value(entry, :ok, fn {key, value} ->
      key = to_string(key)

      cond do
        key in @secret_keys -> {:error, {:invalid, key, "inline secrets are not allowed in #{name}; use token_file or token_env"}}
        key not in @fields -> {:error, {:invalid, key, "unsupported field in #{name}"}}
        key != "allows" and not plain?(value) -> {:error, {:invalid, key, "expected a plain string in #{name}"}}
        true -> nil
      end
    end)
  end

  # The launcher's awk parser rejects escapes, so the file may not carry them.
  defp plain?(value), do: is_binary(value) and value != "" and not String.contains?(value, ["\"", "'", "\\", "\n", "\t"])

  defp allows(_name, nil), do: {:ok, %{categories: ["read"], credentials: []}}

  defp allows(name, %{} = allows) do
    with :ok <- unknown_keys(name, allows),
         {:ok, categories} <- categories(name, Map.get(allows, "categories", ["read"])),
         {:ok, credentials} <- credentials(name, Map.get(allows, "credentials", [])) do
      {:ok, %{categories: categories, credentials: credentials}}
    end
  end

  defp allows(name, _other), do: {:error, {:invalid, "allows", "expected a map in #{name}"}}

  defp unknown_keys(name, allows) do
    case Map.keys(allows) -- ["categories", "credentials"] do
      [] -> :ok
      [key | _] -> {:error, {:invalid, to_string(key), "unsupported allows key in #{name}"}}
    end
  end

  defp categories(name, list) when is_list(list) do
    case Enum.find(list, &(&1 not in @categories)) do
      nil -> {:ok, Enum.uniq(list)}
      "trust" -> {:error, {:invalid, "trust", "is not a grantable category in #{name}"}}
      other -> {:error, {:invalid, "categories", "unknown category #{inspect(other)} in #{name}"}}
    end
  end

  defp categories(name, _other), do: {:error, {:invalid, "categories", "expected a list in #{name}"}}

  defp credentials(name, list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and Regex.match?(@name, &1))),
      do: {:ok, Enum.uniq(list)},
      else: {:error, {:invalid, "credentials", "expected client token names in #{name}"}}
  end

  defp credentials(name, _other), do: {:error, {:invalid, "credentials", "expected a list in #{name}"}}

  defp unique_ids(peers) do
    ids = peers |> Map.values() |> Enum.map(& &1.gateway_id) |> Enum.reject(&is_nil/1)
    check(length(ids) == length(Enum.uniq(ids)), "gateway_id", "duplicated across instances")
  end

  defp check(true, _key, _message), do: :ok
  defp check(false, key, message), do: {:error, {:invalid, key, message}}

  @doc """
  Applies `fun` to the raw `instances` map and writes the result atomically (mode 0600).

  `fun` returns the new instances map, or `{:error, reason}` to abort. The new file is validated
  before it replaces the old one. One audit line per peer whose grants changed names `actor`.
  """
  @spec write((map() -> map() | {:error, term()}), String.t()) :: :ok | {:error, term()}
  def write(fun, actor) when is_function(fun, 1) and is_binary(actor) do
    :global.trans({{__MODULE__, :write}, self()}, fn -> locked_write(fun, actor) end)
  end

  defp locked_write(fun, actor) do
    with {:ok, old} <- load(),
         new_instances when is_map(new_instances) <- fun.(old.instances),
         raw = %{"version" => 1, "instances" => new_instances},
         {:ok, new} <- validate(raw),
         :ok <- File.mkdir_p(Path.dirname(path())),
         :ok <- Aiur.Fs.atomic_write(path(), emit(new_instances), mode: 0o600) do
      :persistent_term.put({__MODULE__, path()}, {identity(), {:ok, new}})
      audit_write(old, new, actor)
    else
      {:error, _} = error -> error
      other -> {:error, {:aborted, other}}
    end
  end

  defp audit_write(old, new, actor) do
    for {name, peer} <- new.peers, grants(old.peers[name]) != grants(peer) do
      Audit.append(%{at: now(), event: "grant_written", actor: actor, peer: peer.gateway_id, name: name, categories: peer.categories})
    end

    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp emit(instances) do
    body = instances |> Enum.sort() |> Enum.map(fn {name, entry} -> ["  ", to_string(name), ":\n", entry_lines(entry)] end)
    ["version: 1\ninstances:\n" | body]
  end

  defp entry_lines(entry) do
    scalars = for key <- @fields -- ["allows"], value = entry[key], do: ["    ", key, ": \"", value, "\"\n"]
    scalars ++ allows_lines(entry["allows"])
  end

  defp allows_lines(nil), do: []

  defp allows_lines(allows) do
    categories = ["      categories: [", Enum.join(Map.get(allows, "categories", ["read"]), ", "), "]\n"]

    credentials =
      case Map.get(allows, "credentials", []) do
        [] -> []
        names -> ["      credentials: [", Enum.join(names, ", "), "]\n"]
      end

    ["    allows:\n", categories, credentials]
  end
end
