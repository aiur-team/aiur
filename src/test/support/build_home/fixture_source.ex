defmodule Aiur.TestSupport.BuildHome.FixtureSource do
  @moduledoc "Frozen v1 build datasets, bounded to active history days in the socket zone."
  @behaviour AiurWeb.Build.DataSource

  alias AiurWeb.Build.Read

  @files ~w(live dense newrepo noqueue offline)
  @dir Path.expand("../../fixtures/build_home", __DIR__)

  def datasets, do: @files ++ ~w(unavailable hold)

  def configure_usage(:ok) do
    config = Application.get_env(:aiur, AiurWeb.Endpoint, [])
    Application.put_env(:aiur, AiurWeb.Endpoint, Keyword.put(config, :build_usage_source, __MODULE__))
  end

  def read(financial, _opts \\ [])
  def read(:locked, _opts), do: Read.locked_usage()

  def read({:ok, _context}, _opts) do
    result = if dataset([]) in @files, do: full([]), else: {:error, :fixture_unavailable}

    case result do
      {:ok, data} -> data["usage"]
      {:error, _reason} -> %{"state" => "unavailable", "observed_at" => nil, "reason" => "fixture_unavailable"}
    end
  end

  @impl true
  def subscribe(_opts), do: Phoenix.PubSub.subscribe(Aiur.PubSub, "build-home:fixture")

  @impl true
  def snapshot(opts) do
    with {:ok, data} <- full(opts) do
      days = if dataset(opts) == "dense", do: 1, else: 2
      zone = Keyword.get(opts, :time_zone, data["history"]["tz"])
      {rows, history} = page(data, nil, zone, days)
      data = data |> put_in(["sections", "hist"], rows) |> Map.put("history", history)
      usage = if opts[:financial] == :locked, do: Read.locked_usage(), else: data["usage"]
      {:ok, Map.put(data, "usage", usage)}
    end
  end

  @impl true
  def earlier(before, zone, opts) do
    with {:ok, data} <- full(opts) do
      {rows, history} = page(data, before, zone, Keyword.get(opts, :days, 1))
      {:ok, %{"rows" => rows, "history" => history}}
    end
  end

  def full(opts), do: load(dataset(opts), Keyword.get(opts, :dir, @dir))
  defp dataset(opts), do: Keyword.get(opts, :dataset, Application.get_env(:aiur, :build_fixture_dataset, "live"))
  defp load("unavailable", _dir), do: {:error, :fixture_unavailable}

  defp load("hold", _dir) do
    receive do
      :release -> {:error, :fixture_unavailable}
    end
  end

  defp load(dataset, dir) when dataset in @files do
    path = Path.join(dir, dataset <> ".json")

    with {:ok, body} <- File.read(path), {:ok, json} <- Jason.decode(body) do
      {:ok, json}
    else
      _error -> {:error, {:fixture_missing, path}}
    end
  end

  defp load(_dataset, _dir), do: {:error, :unknown_dataset}

  defp page(data, before, zone, days) do
    rows = data["sections"]["hist"]
    groups = Enum.group_by(rows, &midnight(&1["end"], zone))
    available = groups |> Map.keys() |> Enum.filter(&(before == nil or &1 < before)) |> Enum.sort(:desc)
    chosen = Enum.take(available, days)
    from = if chosen == [], do: before, else: Enum.min(chosen)
    history = Map.merge(data["history"], %{"from" => from, "more" => length(available) > days, "tz" => zone})
    {Enum.filter(rows, &(midnight(&1["end"], zone) in chosen)), history}
  end

  defp midnight(ms, zone) do
    local = ms |> DateTime.from_unix!(:millisecond) |> DateTime.shift_zone!(zone, Tz.TimeZoneDatabase)
    local |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], zone, Tz.TimeZoneDatabase) |> DateTime.to_unix(:millisecond)
  end
end
