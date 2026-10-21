defmodule Aiur.BrowserHarness.IndexLiveFixture do
  @moduledoc false
  use Phoenix.Controller, formats: []
  alias Aiur.TestSupport.BuildHome.IndexSeed
  alias AiurWeb.Build.Index

  defmodule Daemon do
    def read_daemon(_), do: %{state: "live", heartbeat_at: 1_791_408_000_000, observed_at: 1_791_408_000_000}
  end

  defmodule Source do
    @behaviour AiurWeb.Build.DataSource
    @impl true
    def ticket(id, opts), do: selected().ticket(id, opts)

    alias Aiur.TestSupport.BuildHome.FixtureSource
    alias AiurWeb.Build.IndexSource
    @impl true
    def subscribe(opts), do: selected().subscribe(opts)
    @impl true
    def snapshot(opts), do: selected().snapshot(opts)
    @impl true
    def earlier(before, zone, opts), do: selected().earlier(before, zone, opts)
    defp selected, do: if(Application.get_env(:aiur, :build_fixture_dataset) == "index-live", do: IndexSource, else: FixtureSource)
  end

  defmodule Usage do
    alias Aiur.TestSupport.BuildHome.FixtureSource
    alias AiurWeb.Build.Read
    def subscribe(_), do: :ok
    def read(:locked, _), do: Read.locked_usage()

    def read(_, _) do
      {:ok, data} = FixtureSource.full(dataset: "live")
      data["usage"]
    end
  end

  def configure(conn, _params) do
    name = __MODULE__.Index

    unless Process.whereis(name) do
      dir = Path.join(System.tmp_dir!(), "aiur-index-live-#{System.unique_integer([:positive])}")
      seed = IndexSeed.start("live", dir)
      # Fixture server owns these temporary stores for its lifetime.
      Enum.each(seed.processes, &Process.unlink/1)

      {:ok, pid} =
        Index.start_link(name: name, broadcast: &broadcast/1, subscribe: fn -> :ok end, read: fn _, _, _ -> seed.parts end, daemon_read: &Daemon.read_daemon/1, clock: fn -> seed.data["now"] end)

      Process.unlink(pid)
    end

    Application.put_env(:aiur, :build_fixture_dataset, "index-live")
    Application.put_env(:aiur, :build_data_source, {Source, [server: name, usage: Usage, freshness: Daemon, index_subscribe: &subscribe/0]})
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    redirect(conn, to: "/build" <> query)
  end

  defp broadcast(changes), do: Phoenix.PubSub.broadcast(Aiur.PubSub, "build-home:index-live-fixture", {:build_changes, changes})
  defp subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, "build-home:index-live-fixture")
end
