defmodule Aiur.Experiments.Auto.DeployLedger do
  @moduledoc false
  use GenServer

  alias Aiur.Experiments.Auto.BuildStamp
  alias Aiur.Experiments.Paths

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    case record_boot(opts) do
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:stop, {:deploy_ledger, reason}}
    end
  end

  @spec record_boot(keyword()) :: {:ok, map()} | {:error, term()}
  def record_boot(opts \\ []) do
    path = Keyword.get(opts, :path, path())
    row = boot_row(opts)

    with :ok <- Aiur.Journal.prepare(Path.dirname(path), path),
         {:ok, rows} <- read(path, true) do
      case Enum.find(rows, &(&1["boot_id"] == row["boot_id"])) do
        nil -> append(path, row, rows)
        existing -> retain_existing(path, rows, existing)
      end
    end
  end

  defp retain_existing(path, rows, existing) do
    with :ok <- cap(path, rows), do: {:ok, existing}
  end

  @spec previous(keyword()) :: {:ok, map() | nil} | {:error, term()}
  def previous(opts \\ []) do
    boot_id = Keyword.get(opts, :boot_id, Aiur.Boot.run_id())
    with {:ok, rows} <- read(Keyword.get(opts, :path, path()), false), do: {:ok, rows |> Enum.take_while(&(&1["boot_id"] != boot_id)) |> List.last()}
  end

  @spec list({DateTime.t(), DateTime.t()}, keyword()) :: {:ok, [map()]} | {:error, term()}
  def list({from, until}, opts \\ []) do
    with {:ok, rows} <- read(Keyword.get(opts, :path, path()), false) do
      {:ok,
       Enum.filter(rows, fn row ->
         {:ok, at, _offset} = DateTime.from_iso8601(row["at"])
         DateTime.compare(at, from) != :lt and DateTime.compare(at, until) == :lt
       end)}
    end
  end

  defp append(path, row, rows) do
    with :ok <- Aiur.Journal.append(path, row), :ok <- cap(path, rows ++ [row]), do: {:ok, row}
  end

  defp path, do: Path.join(Paths.root(), "deploys.ndjson")

  defp boot_row(opts) do
    version = Keyword.get(opts, :aiur_version, Aiur.Identity.instance_section().aiur_version)
    dir = Keyword.get(opts, :release_dir, System.get_env("AIUR_RELEASE_DIR"))
    stamp = BuildStamp.read(dir)
    base = BuildStamp.base_version(version)

    %{
      "boot_id" => Keyword.get(opts, :boot_id, Aiur.Boot.run_id()),
      "at" => opts |> Keyword.get(:at, Aiur.Boot.started_at()) |> DateTime.to_iso8601(),
      "aiur_version" => version,
      "base_version" => if(base == :unknown, do: nil, else: base),
      "source_sha" => stamp.source_sha,
      "dirty" => stamp.dirty,
      "launcher" => if(is_binary(dir) and String.ends_with?(dir, "/src/_build/dev/rel/aiur"), do: "dev", else: "release"),
      "instance_id" => Keyword.get(opts, :instance_id, Aiur.Identity.instance_id())
    }
  end

  defp read(path, repair?) do
    case Aiur.Journal.replay(path, &validate/1, repair_torn_tail: repair?) do
      {:ok, rows, nil} -> {:ok, rows}
      {:ok, _rows, corruption} -> {:error, corruption}
      error -> error
    end
  end

  defp validate(%{"boot_id" => id, "at" => at} = row) when is_binary(id) and is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, _time, _offset} -> {:ok, row}
      _invalid -> {:error, :invalid_deploy_time}
    end
  end

  defp validate(_row), do: {:error, :invalid_deploy}

  defp cap(path, rows) when length(rows) > 5_000 do
    contents = rows |> Enum.take(-5_000) |> Enum.map(&[Jason.encode!(&1), "\n"])
    Aiur.Fs.atomic_write(path, contents, fsync: true, mode: 0o600)
  end

  defp cap(_path, _rows), do: :ok
end
