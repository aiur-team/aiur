defmodule Aiur.TestSupport.BuildHome.FixtureSource do
  @moduledoc "Frozen v1 build datasets, bounded to active history days in the socket zone."
  @behaviour AiurWeb.Build.DataSource

  alias Aiur.TestSupport.BuildHome.{ControlFixture, EarlierControl, Scale}
  alias AiurWeb.Build.Read

  @files ~w(live dense newrepo noqueue offline odd-edges unknowns hostile chains list-edges now0 now24)
  # In-memory scale sets derived from dense (MP-E8-C12-T06); no committed 10,000-row file.
  @scaled ~w(scale10k nq300 nq1000 agents20)
  @dir Path.expand("../../fixtures/build_home", __DIR__)

  def datasets, do: @files ++ @scaled ++ ~w(degraded unavailable hold)
  def scaled, do: @scaled

  def configure_usage(:ok) do
    config = Application.get_env(:aiur, AiurWeb.Endpoint, [])
    Application.put_env(:aiur, AiurWeb.Endpoint, Keyword.put(config, :build_usage_source, __MODULE__))
  end

  def read(financial, _opts \\ [])
  def read(:locked, _opts), do: Read.locked_usage()

  def read({:ok, _context}, _opts) do
    result = if dataset([]) in (@files ++ @scaled ++ ["degraded"]), do: full([]), else: {:error, :fixture_unavailable}

    case result do
      {:ok, data} -> data["usage"]
      {:error, _reason} -> %{"state" => "unavailable", "observed_at" => nil, "reason" => "fixture_unavailable"}
    end
  end

  @impl true
  def subscribe(_opts), do: Phoenix.PubSub.subscribe(Aiur.PubSub, topic(stream()))

  def topic(nil), do: "build-home:fixture"
  def topic(stream), do: "build-home:fixture:" <> stream

  # The browser harness registers each page's transport under its stream key; see FixtureLiveSocket.
  defp stream do
    with pid when is_pid(pid) <- Process.get(:"$phx_transport_pid"),
         true <- is_pid(Process.whereis(__MODULE__.Streams)),
         [stream] <- Registry.keys(__MODULE__.Streams, pid) do
      stream
    else
      _ -> nil
    end
  end

  @impl true
  def snapshot(opts) do
    with {:ok, data} <- full(opts) do
      days = if dataset(opts) in ["dense" | @scaled], do: 1, else: 2
      zone = Keyword.get(opts, :time_zone, data["history"]["tz"])
      {rows, history} = page(data, nil, zone, days, opts)
      data = data |> put_in(["sections", "hist"], rows) |> Map.put("history", history)
      usage = if opts[:financial] == :locked, do: Read.locked_usage(), else: data["usage"]
      {:ok, Map.put(data, "usage", usage)}
    end
  end

  @impl true
  def earlier(before, zone, opts) do
    EarlierControl.run(before, fn ->
      with {:ok, data} <- full(opts) do
        {rows, history} = page(data, before, zone, Keyword.get(opts, :days, 1), opts)
        {:ok, %{"rows" => rows, "history" => history}}
      end
    end)
  end

  @impl true
  def ticket(id, opts) do
    with {:ok, data} <- full(opts) do
      case data["sections"] |> Map.values() |> List.flatten() |> Enum.find(&(&1["id"] == id)) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end
  end

  @impl true
  def unit_row(id, opts), do: ControlFixture.unit_row(id, opts)

  def full(opts), do: load(dataset(opts), Keyword.get(opts, :dir, @dir))

  @impl true
  def ticket_doc_identity(id, opts) do
    with {:ok, row} <- ticket(id, opts) do
      Aiur.TrackerIdentity.from_github(
        %{"node_id" => "build-fixture:#{dataset(opts)}:#{id}", "number" => row["num"]},
        {"fixture", "build-home"},
        {"fixture", "build-home"}
      )
    end
  end

  defp dataset(opts), do: Keyword.get(opts, :dataset, Application.get_env(:aiur, :build_fixture_dataset, "live"))
  defp load("unavailable", _dir), do: {:error, :fixture_unavailable}

  defp load("degraded", dir) do
    with {:ok, data} <- load("live", dir) do
      now = data["now"]

      sources =
        data["sources"]
        |> Map.put("history", %{"state" => "unavailable", "observed_at" => now - 12 * 60_000, "reason" => "timeout"})
        |> Map.put("queue", %{"state" => "disabled", "observed_at" => nil, "reason" => "build queue is off in .aiur/config"})
        |> Map.put("index", %{"state" => "stale", "observed_at" => now - 3 * 3_600_000, "reason" => nil})

      {:ok,
       data
       |> put_in(["sections", "hist"], [])
       |> put_in(["sections", "plan"], [])
       |> Map.put("history", Map.merge(data["history"], %{"more" => false, "total" => 0, "undated" => 0}))
       |> Map.put("sources", sources)}
    end
  end

  defp load("hold", _dir) do
    receive do
      :release -> {:error, :fixture_unavailable}
    end
  end

  defp load(dataset, dir) when dataset in @files do
    path = Path.join(dir, dataset <> ".json")

    with {:ok, body} <- File.read(path), {:ok, json} <- Jason.decode(body) do
      {:ok, if(dataset == "hostile", do: json["snapshot"], else: json)}
    else
      _error -> {:error, {:fixture_missing, path}}
    end
  end

  defp load(dataset, dir) when dataset in @scaled do
    key = {__MODULE__, dataset, dir}

    case :persistent_term.get(key, nil) do
      nil ->
        with {:ok, dense} <- load("dense", dir) do
          data = scale(dataset, dense)
          :persistent_term.put(key, data)
          {:ok, data}
        end

      data ->
        {:ok, data}
    end
  end

  defp load(_dataset, _dir), do: {:error, :unknown_dataset}

  defp scale("scale10k", dense), do: Scale.dataset(dense, 10_000)
  defp scale("nq300", dense), do: Scale.with_nq(dense, 300)
  defp scale("nq1000", dense), do: Scale.with_nq(dense, 1_000)
  defp scale("agents20", dense), do: dense |> Scale.dataset(10_000) |> Scale.with_active(20)

  defp page(data, before, zone, days, opts) do
    rows = data["sections"]["hist"]
    groups = groups(dataset(opts), Keyword.get(opts, :dir, @dir), rows, zone)
    available = groups |> Map.keys() |> Enum.filter(&(before == nil or &1 < before)) |> Enum.sort(:desc)
    chosen = Enum.take(available, days)
    from = if chosen == [], do: before, else: Enum.min(chosen)
    history = Map.merge(data["history"], %{"from" => from, "more" => length(available) > days, "tz" => zone})
    ids = chosen |> Enum.flat_map(&Map.fetch!(groups, &1)) |> MapSet.new(& &1["id"])
    {Enum.filter(rows, &MapSet.member?(ids, &1["id"])), history}
  end

  # Grouping thousands of rows by local day costs hundreds of milliseconds per request; the
  # dense-derived sets keep it once per VM so perf specs measure the page, not the fixture.
  defp groups(dataset, dir, rows, zone) when dataset in ["dense" | @scaled] do
    key = {__MODULE__, :groups, dataset, dir, zone}

    case :persistent_term.get(key, nil) do
      nil -> tap(Enum.group_by(rows, &midnight(&1["end"], zone)), &:persistent_term.put(key, &1))
      groups -> groups
    end
  end

  defp groups(_dataset, _dir, rows, zone), do: Enum.group_by(rows, &midnight(&1["end"], zone))

  defp midnight(ms, zone) do
    local = ms |> DateTime.from_unix!(:millisecond) |> DateTime.shift_zone!(zone, Tz.TimeZoneDatabase)
    local |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], zone, Tz.TimeZoneDatabase) |> DateTime.to_unix(:millisecond)
  end
end
