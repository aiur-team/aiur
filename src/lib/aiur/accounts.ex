defmodule Aiur.Accounts do
  @moduledoc "Machine-local harness accounts and pure account selection."

  @registry "machine"

  @type account :: %{name: String.t(), harness: String.t(), profile_dir: Path.t() | nil}
  @type usage :: %{optional(String.t()) => number() | nil}
  @type registry_entry :: %{optional(String.t()) => String.t() | nil}

  @spec list(String.t() | nil) :: [account()]
  def list(harness \\ nil) do
    registry()
    |> Map.put_new("default", %{"harness" => "claude", "profile_dir" => nil})
    |> Enum.flat_map(fn {name, entry} ->
      if is_nil(harness) or entry["harness"] == harness do
        [%{name: name, harness: entry["harness"], profile_dir: entry["profile_dir"]}]
      else
        []
      end
    end)
    |> Enum.sort_by(&{&1.harness, &1.name})
  end

  @spec profile_env(String.t(), String.t()) :: [{String.t(), String.t()}]
  def profile_env(harness, name) do
    case account(harness, name) do
      {:ok, %{profile_dir: nil}} -> []
      {:ok, %{profile_dir: dir}} -> shim!(harness).profile_env(dir)
      :error -> []
    end
  end

  @spec usage(String.t(), String.t()) :: term()
  def usage(harness, name) do
    case account(harness, name) do
      {:ok, %{profile_dir: dir}} -> shim!(harness).usage(dir)
      :error -> {:error, :unknown_account}
    end
  end

  @spec configured_names() :: [String.t()]
  def configured_names do
    case Aiur.Config.settings() do
      {:ok, %{agent: %{accounts: accounts}}} when is_map(accounts) ->
        Map.get(accounts, "claude", Map.get(accounts, :claude, []))

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
  def register(harness, name, profile_dir) do
    with true <- supported?(harness),
         true <- valid_name?(name),
         {:ok, dir} <- ensure_profile(harness, name, profile_dir),
         :ok <- link_shared(harness, dir) do
      write_entry(name, %{"harness" => harness, "profile_dir" => dir})
    else
      false -> {:error, :invalid_account}
      {:error, _} = error -> error
    end
  end

  @spec logout(String.t(), boolean()) :: :ok | {:error, term()}
  def logout("default", _purge), do: {:error, :default_account_protected}

  def logout(name, purge) do
    case Map.pop(registry(), name) do
      {nil, _} ->
        {:error, :unknown_account}

      {entry, rest} ->
        with :ok <- write_registry(rest) do
          maybe_purge(entry, purge)
        end
    end
  end

  @spec login_command(String.t(), String.t()) :: {String.t(), [String.t()]} | {:error, term()}
  def login_command(harness, name) do
    case account(harness, name) do
      {:ok, %{profile_dir: nil}} -> {:error, :default_login_uses_existing_profile}
      {:ok, %{profile_dir: dir}} -> shim!(harness).login_command(dir)
      :error -> {:error, :unknown_account}
    end
  end

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
    entries = Map.put_new(registry(), "default", %{"harness" => "claude"})

    case Map.get(entries, name) do
      %{"harness" => ^harness, "profile_dir" => dir} -> {:ok, %{name: name, harness: harness, profile_dir: dir}}
      %{"harness" => ^harness} -> {:ok, %{name: name, harness: harness, profile_dir: nil}}
      _ -> :error
    end
  end

  defp supported?("claude"), do: true
  defp supported?(_), do: false
  defp shim!("claude"), do: Aiur.Accounts.Shims.Claude

  defp ensure_profile(_harness, _name, dir) when is_binary(dir) do
    expanded = Path.expand(dir)

    cond do
      expanded == Path.join(System.get_env("HOME") || Path.expand("~"), ".claude") -> {:error, :default_profile_already_reserved}
      File.dir?(expanded) -> {:ok, expanded}
      true -> {:error, :profile_directory_missing}
    end
  end

  defp ensure_profile(harness, name, nil) do
    dir = Path.join([accounts_root(), harness, name])
    with :ok <- File.mkdir_p(dir), do: {:ok, dir}
  end

  defp link_shared("claude", dir) do
    source = Path.join(System.get_env("HOME") || Path.expand("~"), ".claude")
    shim = shim!("claude")

    Enum.reduce_while(shim.shared_paths(), :ok, fn relative, :ok ->
      case link_shared_path(source, relative, dir, shim.never_shared()) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

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

  defp maybe_purge(%{"profile_dir" => dir}, true) do
    _removed = File.rm_rf!(IO.iodata_to_binary(dir))
    :ok
  end

  defp maybe_purge(_entry, _purge), do: :ok

  defp write_entry(name, entry), do: write_registry(Map.put(registry(), name, entry))

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
