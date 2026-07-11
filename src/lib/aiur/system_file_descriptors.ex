defmodule Aiur.SystemFileDescriptors do
  @moduledoc """
  Reads per-process file-descriptor usage and the soft open-file limit.

  Linux exposes both values through procfs. The Aiur launcher also exports the
  daemon's effective post-raise soft limit so the self-process sample can use
  `/dev/fd` on platforms without procfs. Missing or malformed data returns
  `:unavailable`; an `:emfile` read failure returns `:exhausted` so admission
  callers fail closed at the point where another descriptor cannot be opened.
  """

  @soft_limit_env "AIUR_NOFILE_SOFT_LIMIT"

  @type sample :: %{
          pid: String.t(),
          used: non_neg_integer(),
          limit: pos_integer(),
          available: non_neg_integer(),
          headroom_ratio: float()
        }
  @type sample_result :: sample() | :unavailable | :exhausted

  @doc """
  Samples the Aiur daemon process.

  The application override is a test seam for dispatch integration tests; real
  callers always use the OS-backed sampler.
  """
  @spec sample() :: sample_result()
  def sample do
    case Application.get_env(:aiur, :file_descriptor_sample_override) do
      source when is_function(source, 0) -> source.()
      _other -> sample(System.pid())
    end
  rescue
    _error -> :unavailable
  catch
    :exit, _reason -> :unavailable
  end

  @doc "Samples the OS process identified by `pid`."
  @spec sample(pos_integer() | String.t()) :: sample_result()
  def sample(pid), do: sample(pid, [])

  @doc false
  @spec sample(pos_integer() | String.t(), keyword()) :: sample_result()
  def sample(pid, opts) when is_list(opts) do
    with {:ok, normalized_pid} <- normalize_pid(pid) do
      descriptor_source = Keyword.get(opts, :descriptor_source, &descriptor_entries/1)
      limit_source = Keyword.get(opts, :limit_source, &soft_limit/1)
      build_sample(normalized_pid, descriptor_source, limit_source)
    else
      _error -> :unavailable
    end
  rescue
    _error -> :unavailable
  catch
    :exit, _reason -> :unavailable
  end

  @doc false
  @spec parse_soft_limit(term()) :: {:ok, pos_integer()} | {:error, :unavailable}
  def parse_soft_limit(contents) when is_binary(contents) do
    token =
      case Regex.run(~r/^\s*Max open files\s+(\S+)/m, contents, capture: :all_but_first) do
        [value] -> value
        nil -> String.trim(contents)
      end

    case Integer.parse(token) do
      {limit, ""} when limit > 0 -> {:ok, limit}
      _other -> {:error, :unavailable}
    end
  end

  def parse_soft_limit(_contents), do: {:error, :unavailable}

  defp build_sample(pid, descriptor_source, limit_source) do
    with {:ok, entries} when is_list(entries) <- descriptor_source.(pid),
         {:ok, limit} when is_integer(limit) and limit > 0 <- limit_source.(pid) do
      used = Enum.count(entries, &descriptor_entry?/1)
      available = max(limit - used, 0)

      %{
        pid: pid,
        used: used,
        limit: limit,
        available: available,
        headroom_ratio: available / limit
      }
    else
      {:error, :emfile} -> :exhausted
      _error -> :unavailable
    end
  end

  defp normalize_pid(pid) when is_integer(pid) and pid > 0, do: {:ok, Integer.to_string(pid)}

  defp normalize_pid(pid) when is_binary(pid) do
    case Integer.parse(String.trim(pid)) do
      {value, ""} when value > 0 -> {:ok, Integer.to_string(value)}
      _other -> {:error, :invalid_pid}
    end
  end

  defp normalize_pid(_pid), do: {:error, :invalid_pid}

  defp descriptor_entries(pid) do
    proc_path = Path.join(["/proc", pid, "fd"])
    self_pid = System.pid()

    case File.ls(proc_path) do
      {:error, reason} when pid == self_pid and reason in [:enoent, :enotdir] -> File.ls("/dev/fd")
      result -> result
    end
  end

  defp soft_limit(pid) do
    case launcher_soft_limit(pid) do
      {:ok, limit} -> {:ok, limit}
      _error -> proc_soft_limit(pid)
    end
  end

  defp launcher_soft_limit(pid) do
    if pid == System.pid() do
      @soft_limit_env
      |> System.get_env()
      |> parse_soft_limit()
    else
      {:error, :unavailable}
    end
  end

  defp proc_soft_limit(pid) do
    with {:ok, contents} <- File.read(Path.join(["/proc", pid, "limits"])) do
      parse_soft_limit(contents)
    end
  end

  defp descriptor_entry?(entry) when is_binary(entry) do
    case Integer.parse(entry) do
      {descriptor, ""} when descriptor >= 0 -> true
      _other -> false
    end
  end

  defp descriptor_entry?(_entry), do: false
end
