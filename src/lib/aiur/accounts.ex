defmodule Aiur.Accounts do
  @moduledoc "Machine-local harness accounts and pure account selection."

  alias Aiur.Accounts.SessionMove
  alias Aiur.Init.Dotenv

  @registry "machine"

  @type account :: %{required(:name) => String.t(), required(:harness) => String.t(), optional(:profile_dir) => Path.t() | nil, optional(:api_key_env) => String.t()}
  @type usage :: %{optional(String.t()) => number() | nil}
  @type registry_entry :: %{optional(String.t()) => String.t() | nil}

  @spec list(String.t() | nil) :: [account()]
  def list(harness \\ nil) do
    registry()
    |> normalize_registry()
    |> add_default_accounts()
    |> Map.to_list()
    |> list_entries(harness)
    |> Enum.sort_by(&{&1.harness, &1.name})
  end

  defp list_entries(entries, harness) do
    for {name, entry} <- entries, is_nil(harness) or entry["harness"] == harness do
      account = %{name: entry_name(name), harness: entry["harness"]}
      account = put_if_binary(account, :profile_dir, entry["profile_dir"])
      put_if_binary(account, :api_key_env, entry["api_key_env"])
    end
  end

  defp put_if_binary(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp put_if_binary(map, :profile_dir, _value), do: Map.put(map, :profile_dir, nil)
  defp put_if_binary(map, _key, _value), do: map

  @spec profile_env(String.t(), String.t()) :: [{String.t(), String.t()}]
  def profile_env(harness, name) do
    case account(harness, name) do
      {:ok, %{profile_dir: nil}} ->
        []

      {:ok, %{api_key_env: _env_name}} ->
        []

      {:ok, %{profile_dir: dir}} ->
        shim_profile_env(shim!(harness), dir)

      :error ->
        []
    end
  end

  @spec capability(String.t()) :: {:ok, map()} | {:error, term()}
  def capability(harness) do
    case Map.get(Aiur.CodingAgent.backends(), harness) do
      %{accounts: %{supported: supported} = capability} when is_boolean(supported) -> {:ok, capability}
      _ -> {:error, :unsupported_account_backend}
    end
  end

  @spec supported?(map()) :: boolean()
  def supported?(%{supported: true, multi: :available}), do: true
  def supported?(_capability), do: false

  @spec usage(String.t(), String.t()) :: term()
  def usage(harness, name) do
    case account(harness, name) do
      {:ok, %{profile_dir: dir}} when is_binary(dir) ->
        shim_usage(shim!(harness), dir)

      {:ok, %{api_key_env: _env_name}} ->
        {:error, :usage_unsupported}

      {:ok, %{profile_dir: nil, harness: harness}} ->
        shim_usage(shim!(harness), nil)

      :error ->
        {:error, :unknown_account}
    end
  end

  @spec configured_names(String.t() | nil) :: [String.t()]
  def configured_names(harness \\ nil) do
    case Aiur.Config.settings() do
      {:ok, %{agent: %{accounts: accounts}}} when is_map(accounts) ->
        if harness do
          Map.get(accounts, harness, [])
        else
          Map.get(accounts, "claude", Map.get(accounts, :claude, []))
        end

      _ ->
        []
    end
  rescue
    _error -> []
  end

  @spec select(String.t(), [String.t()], String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def select(_harness, candidates, mode, usage) when mode in ["balance", "priority"] do
    case mode do
      "priority" -> select_priority(candidates, usage)
      "balance" -> select_balance(candidates, usage)
    end
  end

  def select(_harness, _candidates, _mode, _usage), do: {:error, :invalid_selection_mode}

  @spec register(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def register(harness, name, profile_dir \\ nil) do
    with {:ok, capability} <- capability(harness),
         :supported <- if(supported?(capability), do: :supported, else: :unsupported),
         true <- valid_name?(name),
         {:ok, entry} <- account_entry(harness, name, profile_dir, capability),
         :ok <- maybe_link_shared(harness, entry) do
      write_entry({harness, name}, Map.put(entry, "harness", harness))
    else
      false ->
        case capability(harness) do
          {:ok, %{supported: false, reason: reason}} -> {:error, {:unsupported_account_backend, reason}}
          {:ok, %{supported: true}} -> {:error, :invalid_account}
          _ -> {:error, :unsupported_account_backend}
        end

      :unsupported ->
        case capability(harness) do
          {:ok, %{reason: reason}} -> {:error, {:unsupported_account_backend, reason}}
          _ -> {:error, :unsupported_account_backend}
        end

      {:error, :unsupported_account_backend} ->
        {:error, :unsupported_account_backend}

      {:error, _} = error ->
        error
    end
  end

  @spec logout(String.t(), boolean()) :: :ok | {:error, term()}
  def logout(name, purge), do: logout("claude", name, purge)

  @spec logout(String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def logout(_harness, "default", _purge), do: {:error, :default_account_protected}

  def logout(harness, name, purge) do
    key = registry_key(harness, name)
    entries = normalize_registry(registry())

    case Map.pop(entries, key) do
      {nil, _} ->
        logout_legacy(entries, name, harness, purge)

      {entry, rest} ->
        with :ok <- write_registry(rest) do
          maybe_purge(entry, purge)
        end
    end
  end

  defp logout_legacy(entries, name, harness, purge) do
    case Map.pop(entries, name) do
      {%{"harness" => ^harness} = entry, rest} ->
        with :ok <- write_registry(rest) do
          maybe_purge(entry, purge)
        end

      _ ->
        {:error, :unknown_account}
    end
  end

  @spec login_command(String.t(), String.t()) :: {String.t(), [String.t()]} | {:error, term()}
  def login_command(harness, name) do
    case account(harness, name) do
      {:ok, %{profile_dir: nil}} ->
        {:error, :default_login_uses_existing_profile}

      {:ok, %{profile_dir: dir}} ->
        shim = shim!(harness)
        shim_login_command(shim, dir)

      {:ok, %{api_key_env: _}} ->
        {:error, :api_key_account_uses_env_file}

      :error ->
        {:error, :unknown_account}
    end
  end

  @doc "Moves a paused session's shim-declared artifacts between account profiles."
  @spec move_session(String.t(), String.t(), String.t(), String.t(), Path.t(), keyword()) ::
          :ok | {:error, term()}
  def move_session(harness, source_name, destination_name, session_id, cwd, opts \\ []) do
    with {:ok, source} <- account(harness, source_name),
         {:ok, destination} <- account(harness, destination_name),
         source_dir <- profile_dir(source),
         destination_dir <- profile_dir(destination),
         false <- source_name == destination_name,
         :ok <-
           SessionMove.run(
             fn -> Keyword.get(opts, :shim, shim!(harness)) end,
             source_dir,
             destination_dir,
             session_id,
             cwd,
             opts
           ) do
      :ok
    else
      false -> {:error, :same_account}
      {:error, _} = error -> error
      _ -> {:error, :account_profile_unavailable}
    end
  rescue
    error -> {:error, {:session_move_failed, error}}
  end

  defp profile_dir(%{profile_dir: nil, harness: "claude"}), do: Path.join(System.get_env("HOME") || Path.expand("~"), ".claude")
  defp profile_dir(%{profile_dir: dir}), do: dir

  defp select_priority(candidates, usage) do
    eligible = Enum.filter(candidates, &below_limit?(Map.get(usage, &1)))

    case Enum.find(eligible, &has_usage?(Map.get(usage, &1))) || List.first(eligible) do
      nil -> {:error, :no_available_account}
      name -> {:ok, name}
    end
  end

  defp has_usage?(reading) when is_map(reading),
    do: is_number(Map.get(reading, "seven_day")) or is_number(Map.get(reading, "five_hour"))

  defp has_usage?(_unknown), do: false

  defp select_balance(candidates, usage) do
    selected =
      candidates
      |> Enum.map(&{&1, Map.get(usage, &1)})
      |> Enum.reject(fn {_name, reading} -> at_limit?(reading) end)
      |> Enum.min_by(fn {_name, reading} -> rank(reading) end, fn -> nil end)

    case selected do
      {name, _} -> {:ok, name}
      nil -> {:error, :no_available_account}
    end
  end

  defp rank(%{"seven_day" => week, "five_hour" => five}) when is_number(week) and is_number(five), do: {0, week, five}
  defp rank(%{"seven_day" => week}) when is_number(week), do: {0, week, 101}
  defp rank(_unknown), do: {1, 101, 101}

  defp below_limit?(%{"seven_day" => week}) when is_number(week) and week >= 100, do: false
  defp below_limit?(%{"five_hour" => five}) when is_number(five) and five >= 100, do: false
  defp below_limit?(_unknown), do: true
  defp at_limit?(reading), do: not below_limit?(reading)

  @spec registry() :: %{optional(String.t()) => registry_entry()}
  defp registry do
    case File.read(machine_path()) do
      {:ok, contents} ->
        case YamlElixir.read_from_string(contents) do
          {:ok, %{"accounts" => accounts}} when is_map(accounts) -> accounts
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp account(harness, name) do
    entries = normalize_registry(registry()) |> add_default_accounts()

    case Map.get(entries, registry_key(harness, name)) do
      %{"harness" => ^harness, "profile_dir" => dir} -> {:ok, %{name: name, harness: harness, profile_dir: dir}}
      %{"harness" => ^harness, "api_key_env" => env_name} -> {:ok, %{name: name, harness: harness, api_key_env: env_name}}
      %{"harness" => ^harness} -> {:ok, %{name: name, harness: harness, profile_dir: nil}}
      _ -> :error
    end
  end

  defp shim!(harness) do
    case harness do
      "claude" -> Aiur.Accounts.Shims.Claude
      "codex" -> Aiur.Accounts.Shims.Codex
      _ -> nil
    end
  end

  defp shim_profile_env(nil, _dir), do: []
  defp shim_profile_env(shim, dir), do: shim.profile_env(dir)
  defp shim_usage(nil, _dir), do: {:error, :unsupported_account_backend}
  defp shim_usage(shim, dir), do: shim.usage(dir)

  defp ensure_profile(_harness, _name, dir, shim) when is_binary(dir) do
    expanded = Path.expand(dir)

    cond do
      expanded == shim.profile_root() -> {:error, :default_profile_already_reserved}
      File.dir?(expanded) -> {:ok, expanded}
      true -> {:error, :profile_directory_missing}
    end
  end

  defp ensure_profile(harness, name, nil, _shim) do
    dir = Path.join([accounts_root(), harness, name])
    with :ok <- File.mkdir_p(dir), do: {:ok, dir}
  end

  defp ensure_profile(_harness, _name, _dir, _shim), do: {:error, :unsupported_account_backend}

  defp account_entry(_harness, name, nil, %{kind: :api_key, api_key_env: base_env}) do
    env_name = base_env <> "__" <> String.upcase(name)

    if local_env_value(env_name) do
      {:ok, %{"api_key_env" => env_name}}
    else
      {:error, {:missing_account_key, env_name}}
    end
  end

  defp account_entry(_harness, _name, _profile_dir, %{kind: :api_key}),
    do: {:error, :api_key_account_does_not_use_profile_dir}

  defp account_entry(harness, name, profile_dir, %{kind: :profile}) do
    with {:ok, shim} <- profile_shim(harness),
         {:ok, dir} <- ensure_profile(harness, name, profile_dir, shim) do
      {:ok, %{"profile_dir" => dir}}
    else
      {:error, _} = error -> error
    end
  end

  defp account_entry(_harness, _name, _dir, _capability), do: {:error, :unsupported_account_backend}

  defp profile_shim("claude"), do: {:ok, Aiur.Accounts.Shims.Claude}
  defp profile_shim("codex"), do: {:ok, Aiur.Accounts.Shims.Codex}
  defp profile_shim(_), do: {:error, :unsupported_account_backend}

  defp maybe_link_shared(harness, %{"profile_dir" => dir}), do: link_shared(harness, dir)
  defp maybe_link_shared(_harness, _entry), do: :ok

  defp link_shared(harness, dir), do: link_shared_profile(shim!(harness), dir)

  defp link_shared_profile(shim, dir) when shim in [Aiur.Accounts.Shims.Claude, Aiur.Accounts.Shims.Codex] do
    source = shim.profile_root()

    Enum.reduce_while(shim.shared_paths(), :ok, fn relative, :ok ->
      case link_shared_path(source, relative, dir, shim.never_shared()) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp link_shared_profile(_shim, _dir), do: {:error, :unsupported_account_backend}
  defp shim_login_command(nil, _dir), do: {:error, :unsupported_account_backend}
  defp shim_login_command(shim, dir), do: shim.login_command(dir)

  defp link_shared_path(source, "projects/*/memory", target, _never) do
    source
    |> Path.join("projects/*/memory")
    |> Path.wildcard()
    |> Enum.reduce_while(:ok, fn memory, :ok ->
      relative = Path.relative_to(memory, source)

      case link_path(source, memory, Path.join(target, relative), []) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp link_shared_path(source, relative, target, never),
    do: link_path(source, Path.expand(relative, source), Path.expand(relative, target), never)

  defp link_path(source, from, to, never) do
    relative = Path.relative_to(from, source)

    if Enum.any?(never, &(&1 == relative or String.starts_with?(relative, String.trim_trailing(&1, "*")))) do
      :ok
    else
      with :ok <- File.mkdir_p(Path.dirname(to)) do
        create_link(from, to)
      end
    end
  end

  defp create_link(from, to) do
    cond do
      match?({:ok, _}, File.lstat(to)) -> :ok
      File.exists?(from) -> File.ln_s(from, to)
      true -> :ok
    end
  end

  defp valid_name?(name), do: is_binary(name) and Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/, name) and name != "default"

  defp maybe_purge(%{"profile_dir" => dir, "harness" => harness}, true) when harness in ["claude", "codex"] do
    root = Path.expand(Path.join(accounts_root(), harness))
    profile = Path.expand(dir)

    if String.starts_with?(profile, root <> "/"), do: File.rm_rf!(profile)

    :ok
  end

  defp maybe_purge(_entry, _purge), do: :ok

  defp write_entry({harness, name}, entry) do
    entries = normalize_registry(registry())

    entries = preserve_legacy_entry(entries, harness, name)

    write_registry(Map.put(entries, registry_key(harness, name), entry))
  end

  defp preserve_legacy_entry(entries, harness, name) do
    case Map.pop(entries, registry_key(harness, name)) do
      {nil, _entries} -> entries
      {old, rest} -> Map.put(rest, name, Map.put(old, "harness", harness))
    end
  end

  defp registry_key(harness, name), do: harness <> ":" <> name
  defp entry_name(key), do: key |> String.split(":", parts: 2) |> List.last()

  defp normalize_registry(entries) do
    Map.new(entries, fn {key, entry} ->
      case {String.contains?(key, ":"), entry["harness"]} do
        {false, harness} when is_binary(harness) -> {registry_key(harness, key), entry}
        _ -> {key, entry}
      end
    end)
  end

  defp add_default_accounts(entries) do
    Aiur.CodingAgent.backends()
    |> Enum.filter(fn {_harness, backend} -> get_in(backend, [:accounts, :multi]) == :available end)
    |> Enum.reduce(entries, fn {harness, _backend}, acc ->
      Map.put_new(acc, registry_key(harness, "default"), %{"harness" => harness})
    end)
  end

  defp local_env_value(name) do
    path = Path.join(System.get_env("HOME") || Path.expand("~"), ".aiur/.env")

    case File.read(path) do
      {:ok, contents} ->
        find_env_value(Dotenv.parse(contents), name)

      _ ->
        nil
    end
  end

  defp find_env_value(entries, name), do: Enum.find_value(entries, fn {key, value} -> if key == name, do: nonempty(value), else: nil end)

  defp nonempty(""), do: nil
  defp nonempty(value), do: value

  defp write_registry(accounts) do
    path = machine_path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(%{"accounts" => accounts}, pretty: true), [:binary]) do
      File.chmod(path, 0o600)
    end
  end

  defp machine_path, do: Path.join([System.get_env("HOME") || Path.expand("~"), ".aiur", @registry])
  defp accounts_root, do: Path.join([System.get_env("HOME") || Path.expand("~"), ".aiur", "accounts"])
end
