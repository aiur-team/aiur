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

  @doc "Moves a paused session's shim-declared artifacts between account profiles."
  def move_session(harness, source_name, destination_name, session_id, cwd, opts \\ []) do
    with {:ok, source} <- account(harness, source_name),
         {:ok, destination} <- account(harness, destination_name),
         source_dir <- profile_dir(source),
         destination_dir <- profile_dir(destination),
         false <- source_name == destination_name,
         :ok <- inactive_session(source_dir, session_id, opts),
         shim <- Keyword.get(opts, :shim, shim!(harness)),
         :ok <- no_destination_artifacts(shim.session_artifacts(destination_dir, session_id, cwd)),
         artifacts <- shim.session_artifacts(source_dir, session_id, cwd),
         :ok <- require_session_artifact(artifacts),
         {:ok, movable_artifacts} <- destination_artifact_preflight(artifacts, source_dir, destination_dir),
         :ok <- move_artifacts(movable_artifacts, source_dir, destination_dir, session_id, Keyword.get(opts, :same_device, same_device?(source_dir, destination_dir)), opts) do
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

  defp inactive_session(dir, session_id, opts) do
    registry = Keyword.get(opts, :sessions_registry, Path.join(dir, "sessions"))

    live? =
      Path.wildcard(Path.join(registry, "*.json"))
      |> Enum.any?(fn path ->
        Path.basename(path, ".json") == session_id or
          case File.read(path) do
            {:ok, contents} ->
              case Jason.decode(contents) do
                {:ok, data} -> data["sessionId"] == session_id or data["session_id"] == session_id
                _ -> false
              end

            _ ->
              false
          end
      end)

    if live?, do: {:error, :session_live}, else: :ok
  end

  defp destination_artifact_preflight(artifacts, source_root, destination_root) do
    Enum.reduce_while(artifacts, {:ok, []}, fn source, {:ok, movable} ->
      destination = Path.join(destination_root, Path.relative_to(source, source_root))

      cond do
        not File.exists?(destination) and not match?({:ok, _}, File.lstat(destination)) ->
          {:cont, {:ok, [source | movable]}}

        same_file?(source, destination) ->
          {:cont, {:ok, movable}}

        true ->
          {:halt, {:error, :destination_session_exists}}
      end
    end)
    |> case do
      {:ok, movable} -> {:ok, Enum.reverse(movable)}
      error -> error
    end
  end

  defp no_destination_artifacts([]), do: :ok
  defp no_destination_artifacts(_artifacts), do: {:error, :destination_session_exists}

  defp require_session_artifact([]), do: {:error, :session_artifacts_missing}
  defp require_session_artifact(_artifacts), do: :ok

  defp move_artifacts(artifacts, source_root, destination_root, session_id, same_fs?, opts) do
    operations = Enum.map(artifacts, &{&1, Path.join(destination_root, Path.relative_to(&1, source_root))})
    transfer = if same_fs?, do: rename_artifacts(operations, [], Keyword.get(opts, :rename, &File.rename/2)), else: copy_artifacts(operations, [], Keyword.get(opts, :copy, &File.cp_r/2))

    case transfer do
      :ok ->
        case merge_history(source_root, destination_root, session_id, opts) do
          :ok ->
            if same_fs? do
              :ok
            else
              case remove_sources(operations, Keyword.get(opts, :rm_rf, &File.rm_rf/1)) do
                :ok -> :ok
                {:error, reason, []} -> rollback_copies(operations, {:source_delete_failed, reason})
                {:error, reason, _deleted} -> {:error, {:source_delete_incomplete, reason}}
              end
            end

          {:error, reason} ->
            if same_fs?, do: rollback_renames(Enum.reverse(operations), reason), else: rollback_copies(operations, reason)
        end

      error ->
        error
    end
  end

  defp rename_artifacts([], _moved, _rename), do: :ok

  defp rename_artifacts([{source, destination} | rest], moved, rename) do
    with :ok <- File.mkdir_p(Path.dirname(destination)),
         false <- File.exists?(destination) or match?({:ok, _}, File.lstat(destination)),
         :ok <- rename.(source, destination) do
      rename_artifacts(rest, [{source, destination} | moved], rename)
    else
      true -> rollback_renames(moved, :destination_session_exists)
      {:error, reason} -> rollback_renames(moved, reason)
    end
  end

  defp rollback_renames(moved, reason) do
    rollback =
      Enum.reduce(moved, :ok, fn {source, destination}, :ok ->
        with :ok <- File.mkdir_p(Path.dirname(source)), :ok <- File.rename(destination, source), do: :ok
      end)

    if rollback == :ok, do: {:error, reason}, else: {:error, {:rollback_failed, reason, rollback}}
  end

  defp copy_artifacts([], _copied, _copy), do: :ok

  defp copy_artifacts([{source, destination} | rest], copied, copy) do
    cond do
      File.exists?(destination) or match?({:ok, _}, File.lstat(destination)) ->
        rollback_copies(copied, :destination_session_exists)

      true ->
        with :ok <- File.mkdir_p(Path.dirname(destination)),
             {:ok, _} <- copy.(source, destination),
             true <- same_tree?(source, destination) do
          copy_artifacts(rest, [{source, destination} | copied], copy)
        else
          false ->
            File.rm_rf(destination)
            rollback_copies(copied, :copy_verification_failed)

          {:error, reason} ->
            File.rm_rf(destination)
            rollback_copies(copied, reason)
        end
    end
  end

  defp rollback_copies(copied, reason) do
    rollback =
      Enum.reduce(copied, :ok, fn {_source, destination}, :ok ->
        case File.rm_rf(destination) do
          {:ok, _removed} -> :ok
          {:error, failure, _path} -> {:error, failure}
        end
      end)

    if rollback == :ok, do: {:error, reason}, else: {:error, {:rollback_failed, reason, rollback}}
  end

  defp remove_sources(operations, rm_rf) do
    Enum.reduce_while(operations, {:ok, []}, fn {source, _destination}, {:ok, deleted} ->
      case rm_rf.(source) do
        {:ok, _removed} -> {:cont, {:ok, [source | deleted]}}
        {:error, reason, _path} -> {:halt, {:error, reason, deleted}}
        {:error, reason} -> {:halt, {:error, reason, deleted}}
        {:error, reason, _path, _partial} -> {:halt, {:error, reason, deleted}}
      end
    end)
    |> case do
      {:ok, _deleted} -> :ok
      error -> error
    end
  end

  defp same_tree?(source, destination) do
    case {File.lstat(source), File.lstat(destination)} do
      {{:ok, %{type: :regular}}, {:ok, %{type: :regular}}} ->
        File.read!(source) == File.read!(destination)

      {{:ok, %{type: :directory}}, {:ok, %{type: :directory}}} ->
        left = Path.wildcard(Path.join(source, "**/*"), match_dot: true) |> Enum.map(&Path.relative_to(&1, source)) |> Enum.sort()
        right = Path.wildcard(Path.join(destination, "**/*"), match_dot: true) |> Enum.map(&Path.relative_to(&1, destination)) |> Enum.sort()
        left == right and Enum.all?(left, &same_tree?(Path.join(source, &1), Path.join(destination, &1)))

      _ ->
        false
    end
  end

  defp merge_history(_source, _destination, nil, _opts), do: :ok

  defp merge_history(source, destination, session_id, opts) do
    from = Path.join(source, "history.jsonl")
    to = Path.join(destination, "history.jsonl")

    with {:ok, source_data} <- read_if_present(from), {:ok, dest_data} <- read_if_present(to) do
      merge_history_rows(from, to, source_data, dest_data, session_id, opts)
    end
  end

  defp merge_history_rows(from, to, source_data, dest_data, session_id, opts) do
    session_lines = String.split(source_data, "\n", trim: true) |> Enum.filter(&history_line?(&1, session_id))
    other_lines = String.split(source_data, "\n", trim: true) |> Enum.reject(&history_line?(&1, session_id))
    merged = (String.split(dest_data, "\n", trim: true) ++ session_lines) |> Enum.uniq() |> Enum.sort_by(&history_timestamp/1) |> Enum.join("\n")

    write = Keyword.get(opts, :history_write, &File.write/2)
    merged_data = if(merged == "", do: "", else: merged <> "\n")
    new_source_data = Enum.join(other_lines, "\n")

    case write.(to, merged_data) do
      :ok ->
        case write.(from, new_source_data) do
          :ok ->
            :ok

          {:error, reason} ->
            restore = restore_history(to, dest_data)
            if restore == :ok, do: {:error, reason}, else: {:error, {:history_rollback_failed, reason, restore}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp restore_history(path, data) do
    if data == "" do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        error -> error
      end
    else
      File.write(path, data)
    end
  end

  defp read_if_present(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, :enoent} -> {:ok, ""}
      error -> error
    end
  end

  defp history_line?(line, id) do
    case Jason.decode(line) do
      {:ok, row} -> row["sessionId"] == id or row["session_id"] == id
      _ -> false
    end
  end

  defp history_timestamp(line) do
    case Jason.decode(line) do
      {:ok, row} -> row["timestamp"] || ""
      _ -> ""
    end
  end

  defp same_device?(left, right), do: File.stat!(left).major_device == File.stat!(right).major_device

  defp same_file?(left, right) do
    case {File.stat(left), File.stat(right)} do
      {{:ok, a}, {:ok, b}} -> a.major_device == b.major_device and a.inode == b.inode
      _ -> false
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
