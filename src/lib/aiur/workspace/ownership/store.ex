defmodule Aiur.Workspace.Ownership.Store do
  @moduledoc false

  use GenServer

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.Fs

  @filename "workspace-ownership.receipts"
  @format :aiur_workspace_ownership_receipts
  @format_name :erlang.atom_to_binary(@format)
  @version 1

  # Safe external-term decoding refuses to create atoms. Keep the finite v1
  # receipt vocabulary in this module so a fresh VM can decode receipts that
  # were written before Guardian or RemoteControl have been loaded.
  @v1_receipt_atoms [
    :ticket,
    :generation,
    :owner_id,
    :phase,
    :provider_expected?,
    :provider,
    :provider_cleanup,
    :provisioning,
    :active,
    :reaping,
    :released,
    :not_started,
    :unresolved,
    :failed,
    :succeeded,
    :process_group_id,
    :root_pid,
    :remote,
    :descendant_pids,
    :process_identities,
    :group,
    :root,
    :process,
    :known,
    :gone,
    :unknown,
    :procfs_birth_and_session,
    :ps_birth_and_session
  ]

  @type receipt :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec put(String.t(), receipt(), GenServer.server()) :: :ok | {:error, term()}
  def put(ticket, receipt, server \\ __MODULE__)
      when is_binary(ticket) and is_map(receipt) do
    GenServer.call(server, {:put, ticket, receipt})
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  @spec delete(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def delete(ticket, server \\ __MODULE__) when is_binary(ticket) do
    GenServer.call(server, {:delete, ticket})
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  @spec get(String.t(), GenServer.server()) :: {:ok, receipt() | nil} | {:error, term()}
  def get(ticket, server \\ __MODULE__) when is_binary(ticket) do
    GenServer.call(server, {:get, ticket})
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  @spec all(GenServer.server()) :: {:ok, %{String.t() => receipt()}} | {:error, term()}
  def all(server \\ __MODULE__) do
    GenServer.call(server, :all)
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  @impl true
  def init(opts) do
    sync_fun =
      Keyword.get(
        opts,
        :sync_fun,
        Application.get_env(:aiur, :workspace_ownership_sync_fun, &Fs.sync_filesystem/0)
      )

    with {:ok, dir} <- state_dir(opts),
         :ok <- File.mkdir_p(dir) do
      path = Path.join(dir, @filename)
      open_store(load(path), path, sync_fun)
    else
      {:error, reason} -> {:stop, {:workspace_ownership_store_unavailable, reason}}
    end
  end

  defp open_store({:ok, receipts, new?}, path, sync_fun) do
    case maybe_initialize(path, receipts, new?, sync_fun) do
      :ok -> {:ok, %{path: path, receipts: receipts, sync_fun: sync_fun}}
      {:error, reason} -> {:stop, {:workspace_ownership_store_unavailable, reason}}
    end
  end

  defp open_store({:error, :invalid_receipt_store}, path, sync_fun) do
    recover_corrupt_store(path, sync_fun)
  end

  defp open_store({:error, {:unsupported_receipt_version, version}}, _path, _sync_fun) do
    # A receipts file with our format tag but a version this store cannot decode
    # (e.g. written by a newer store) is intact live data, not corruption.
    # Quarantining it would silently wipe the ownership records it still holds on
    # a downgrade, so fail closed and let an operator restore/migrate it.
    {:stop, {:workspace_ownership_store_unavailable, {:unsupported_receipt_version, version}}}
  end

  defp open_store({:error, reason}, _path, _sync_fun) do
    {:stop, {:workspace_ownership_store_unavailable, reason}}
  end

  @impl true
  def handle_call({:put, ticket, receipt}, _from, state) do
    receipts = Map.put(state.receipts, ticket, receipt)
    persist_reply(receipts, state)
  end

  def handle_call({:delete, ticket}, _from, state) do
    if Map.has_key?(state.receipts, ticket) do
      persist_reply(Map.delete(state.receipts, ticket), state)
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:get, ticket}, _from, state),
    do: {:reply, {:ok, Map.get(state.receipts, ticket)}, state}

  def handle_call(:all, _from, state), do: {:reply, {:ok, state.receipts}, state}

  defp persist_reply(receipts, state) do
    case persist(state.path, receipts, state.sync_fun) do
      :ok -> {:reply, :ok, %{state | receipts: receipts}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp state_dir(opts) do
    case Keyword.get(opts, :state_dir) do
      dir when is_binary(dir) and dir != "" ->
        {:ok, dir}

      _ ->
        configured_state_dir()
    end
  end

  defp configured_state_dir do
    case Application.get_env(:aiur, :workspace_ownership_state_dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> default_state_dir()
    end
  end

  defp default_state_dir do
    with {:ok, root} <- Paths.decision_state_dir(),
         do: {:ok, Path.join(root, "workspace-ownership")}
  end

  defp load(path) do
    case File.read(path) do
      {:ok, binary} -> decode(binary)
      {:error, :enoent} -> {:ok, %{}, true}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp decode(binary) do
    preload_v1_receipt_atoms()

    case :erlang.binary_to_term(binary, [:safe]) do
      {@format, @version, receipts} when is_map(receipts) ->
        {:ok, receipts, false}

      # A valid term carrying our format tag but a different integer version was
      # written by a store we cannot decode (typically a newer one). The bytes
      # are intact — this is not corruption — so report the version separately
      # so the boot path can fail closed instead of quarantining the file away.
      {@format, version, receipts} when is_integer(version) and is_map(receipts) ->
        {:error, {:unsupported_receipt_version, version}}

      _other ->
        {:error, :invalid_receipt_store}
    end
  rescue
    # A `:safe` decode raises on any atom outside the v1 preload vocabulary —
    # which is exactly what a newer store's receipts do when they add a phase,
    # provider, or key atom this build does not know. That is intact live data,
    # not corruption. A realistic v2 with one new atom must fail closed, not be
    # folded into the quarantine path and silently wiped, so read just the outer
    # {format, version} header (never creating atoms) to tell the two apart.
    _ ->
      case newer_version_from_header(binary) do
        nil -> {:error, :invalid_receipt_store}
        version -> {:error, {:unsupported_receipt_version, version}}
      end
  end

  # Reads only the `{format, version}` head of an external-term binary without
  # decoding the receipts body, so a newer-version file whose body carries atoms
  # this build does not know can still be identified without creating those
  # atoms. Returns the version when the header is ours but names a version we
  # cannot read, otherwise nil. This runs only after a `:safe` decode has
  # already failed, and garbage never matches our format head, so it cannot mask
  # genuine corruption.
  defp newer_version_from_header(<<131, rest::binary>>) do
    with {:ok, arity, rest} <- read_tuple_header(rest),
         true <- arity >= 2,
         {:ok, name, rest} <- read_atom_name(rest),
         true <- name == @format_name,
         {:ok, version, _rest} <- read_integer(rest),
         true <- version != @version do
      version
    else
      _ -> nil
    end
  end

  defp newer_version_from_header(_binary), do: nil

  defp read_tuple_header(<<104, arity, rest::binary>>), do: {:ok, arity, rest}
  defp read_tuple_header(<<105, arity::32, rest::binary>>), do: {:ok, arity, rest}
  defp read_tuple_header(_), do: :error

  # ATOM_EXT (100, 2-byte len, latin1) / SMALL_ATOM_EXT (115, 1-byte len, latin1)
  # ATOM_UTF8_EXT (118, 2-byte len, utf8) / SMALL_ATOM_UTF8_EXT (119, 1-byte len,
  # utf8). The raw name bytes are compared against @format_name without
  # creating an atom.
  defp read_atom_name(<<100, len::16, name::binary-size(len), rest::binary>>), do: {:ok, name, rest}
  defp read_atom_name(<<115, len, name::binary-size(len), rest::binary>>), do: {:ok, name, rest}
  defp read_atom_name(<<118, len::16, name::binary-size(len), rest::binary>>), do: {:ok, name, rest}
  defp read_atom_name(<<119, len, name::binary-size(len), rest::binary>>), do: {:ok, name, rest}
  defp read_atom_name(_), do: :error

  defp read_integer(<<97, int, rest::binary>>), do: {:ok, int, rest}
  defp read_integer(<<98, int::32-signed, rest::binary>>), do: {:ok, int, rest}
  defp read_integer(_), do: :error

  defp preload_v1_receipt_atoms do
    Enum.each(@v1_receipt_atoms, &Atom.to_string/1)
  end

  defp maybe_initialize(_path, _receipts, false, _sync_fun), do: :ok
  defp maybe_initialize(path, receipts, true, sync_fun), do: persist(path, receipts, sync_fun)

  # Genuinely undecodable receipts bytes must not block daemon startup: the
  # leases they held are transient runtime state that is re-created on dispatch,
  # so quarantine the unreadable bytes for forensics and re-initialize empty
  # instead of failing the whole application. A version mismatch is handled
  # separately in open_store/3 and is never quarantined away.
  defp recover_corrupt_store(path, sync_fun) do
    case Fs.quarantine(path) do
      :ok ->
        Logger.warning("Quarantined corrupt workspace-ownership receipts store #{path}")

        case maybe_initialize(path, %{}, true, sync_fun) do
          :ok -> {:ok, %{path: path, receipts: %{}, sync_fun: sync_fun}}
          {:error, reason} -> {:stop, {:workspace_ownership_store_unavailable, reason}}
        end

      {:error, reason} ->
        {:stop, {:workspace_ownership_store_unavailable, {:quarantine_failed, reason}}}
    end
  end

  defp persist(path, receipts, sync_fun) do
    contents = :erlang.term_to_binary({@format, @version, receipts})

    with :ok <- Fs.atomic_write(path, contents, fsync: true, mode: 0o600),
         :ok <- sync_fun.() do
      :ok
    else
      {:error, reason} -> {:error, {:persist_failed, reason}}
      other -> {:error, {:persist_failed, other}}
    end
  rescue
    error -> {:error, {:persist_failed, error}}
  catch
    kind, reason -> {:error, {:persist_failed, {kind, reason}}}
  end
end
