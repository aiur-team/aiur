defmodule Aiur.Machine.InstanceRecord do
  @moduledoc "Read-only decoder for launcher records. Record contents are never evaluated."

  @fields ~w(node instance_key session socket surface_mode project_root project_root_source written_at)a
  @keys Map.new(@fields, &{String.upcase(Atom.to_string(&1)), &1})
  @discarded ~w(AGENT_SOCKET AGENT_TMPFILE WORKSPACE_ROOT_FILE TEST_TICKET_IDS TEST_STATE_DIR GITHUB_BUDGET_DIR)
  @required [:node, :session, :socket, :project_root]
  @limit 16 * 1024
  @escapes %{?n => "\n", ?t => "\t", ?r => "\r", ?a => <<7>>, ?b => <<8>>, ?e => <<27>>, ?E => <<27>>, ?f => <<12>>, ?v => <<11>>, ?\\ => "\\", ?' => "'", ?\" => "\""}

  @doc "Decode a record, retaining only gateway fields and counting non-record lines."
  @spec parse(binary()) :: {:ok, map()} | {:error, term()}
  def parse(binary) when byte_size(binary) > @limit, do: {:error, :too_large}

  def parse(binary) do
    binary
    |> String.split("\n", trim: false)
    |> Enum.reduce_while({:ok, %{ignored_lines: 0}}, &parse_line/2)
    |> complete()
  end

  @doc "List .instance records in path order, retaining per-file read and parse errors."
  @spec list(Path.t()) :: [{Path.t(), {:ok, map()} | {:error, term()}}]
  def list(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".instance"))
        |> Enum.sort()
        |> Enum.map(fn name ->
          path = Path.join(dir, name)
          {path, read(path)}
        end)

      {:error, reason} ->
        [{dir, {:error, reason}}]
    end
  end

  defp read(path) do
    with {:ok, %{type: :regular, size: size}} when size <= @limit <- File.stat(path),
         {:ok, result} <- File.open(path, [:read, :binary], &IO.binread(&1, @limit + 1)) do
      case result do
        :eof -> parse("")
        {:error, _} = error -> error
        binary -> parse(binary)
      end
    else
      {:ok, %{size: size}} when size > @limit -> {:error, :too_large}
      {:ok, _} -> {:error, :not_regular}
      {:error, _} = error -> error
    end
  end

  defp parse_line(line, {:ok, record}) do
    case Regex.run(~r/^AIUR_RECORD_([A-Z_]+)=(.*)$/, line) do
      [_, key, value] -> put_value(record, key, value)
      _ -> {:cont, {:ok, Map.update!(record, :ignored_lines, &(&1 + 1))}}
    end
  end

  defp put_value(record, key, value) when is_map_key(@keys, key) or key in @discarded do
    case decode(value) do
      {:ok, decoded} ->
        updated = if field = @keys[key], do: Map.put(record, field, decoded), else: record
        {:cont, {:ok, updated}}

      :error ->
        {:halt, {:error, {:unsupported_value, key}}}
    end
  end

  defp put_value(record, _key, _value), do: {:cont, {:ok, record}}

  defp complete({:ok, record}) do
    if Enum.all?(@required, &(Map.get(record, &1, "") != "")), do: {:ok, record}, else: {:error, :incomplete}
  end

  defp complete(error), do: error

  # Bash emits two single quotes for the empty string, including optional fields.
  defp decode("''"), do: {:ok, ""}
  defp decode("$'" <> rest), do: ansi(rest, [])
  defp decode(value), do: plain(value, [])

  defp plain("", acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  defp plain(<<?\\, char, rest::binary>>, acc), do: plain(rest, [<<char>> | acc])
  defp plain(<<char, _::binary>>, _) when char in ~c"$`'\"();&|<> \t\r\n\\", do: :error
  defp plain(<<char, rest::binary>>, acc), do: plain(rest, [<<char>> | acc])

  defp ansi("'", acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp ansi(<<?\\, ?x, a, b, rest::binary>>, acc) when a in ~c"0123456789abcdefABCDEF" and b in ~c"0123456789abcdefABCDEF",
    do: numeric(<<a, b>>, 16, rest, acc)

  defp ansi(<<?\\, a, b, c, rest::binary>>, acc) when a in ?0..?7 and b in ?0..?7 and c in ?0..?7,
    do: numeric(<<a, b, c>>, 8, rest, acc)

  defp ansi(<<?\\, char, rest::binary>>, acc) when is_map_key(@escapes, char), do: ansi(rest, [@escapes[char] | acc])
  defp ansi(<<char, _::binary>>, _) when char in ~c"\\'", do: :error
  defp ansi(<<char, rest::binary>>, acc), do: ansi(rest, [<<char>> | acc])
  defp ansi("", _), do: :error

  defp numeric(digits, base, rest, acc) do
    case Integer.parse(digits, base) do
      {value, ""} when value in 0..255 -> ansi(rest, [<<value>> | acc])
      _ -> :error
    end
  end
end
