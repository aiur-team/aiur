defmodule Aiur.TestSupport.BuildHome.ProtocolCase do
  @moduledoc false
  use ExUnit.CaseTemplate
  alias Aiur.TestSupport.BuildHome.FixtureSource
  alias AiurWeb.Endpoint

  defmodule Spy do
    @moduledoc false
    @behaviour AiurWeb.Build.DataSource
    @impl true
    def subscribe(opts) do
      send(opts[:test_pid], :subscribed)
      FixtureSource.subscribe(opts)
    end

    @impl true
    def snapshot(opts) do
      send(opts[:test_pid], {:read, Keyword.take(opts, [:time_zone, :financial])})

      result(opts[:mode], opts)
    end

    defp result(:raise, _opts), do: raise("source raised")
    defp result(:exit, _opts), do: exit(:source_exit)
    defp result(:error, _opts), do: {:error, :source_down}
    defp result(:hold, _opts), do: receive(do: (:release -> {:error, :unavailable}))

    defp result(:invalid, opts) do
      {:ok, data} = FixtureSource.snapshot(opts)
      {:ok, put_in(data, ["sections", "now", Access.at(0), "pct"], "sensitive-source-value")}
    end

    defp result(_mode, opts) do
      read_opts = if opts[:ignore_financial], do: Keyword.delete(opts, :financial), else: opts
      {:ok, data} = FixtureSource.snapshot(read_opts)
      {:ok, data |> Map.put("index_generation", 6) |> part_failure(opts)}
    end

    @impl true
    def earlier(before, zone, opts) do
      send(opts[:test_pid], {:earlier, before, zone, opts[:days]})
      FixtureSource.earlier(before, zone, opts)
    end

    defp part_failure(data, opts) do
      if opts[:part_failure], do: data |> put_in(["sections", "plan"], []) |> put_in(["sources", "queue"], %{"state" => "unavailable", "observed_at" => nil, "reason" => "queue_down"}), else: data
    end
  end

  using do
    quote do
      use Aiur.TestSupport
      import Phoenix.ConnTest, except: [build_conn: 0]
      import Phoenix.LiveViewTest
      alias Aiur.TestSupport.BuildHome.ProtocolCase
      import ProtocolCase
      alias AiurWeb.Build.Payload
      @endpoint AiurWeb.Endpoint
      setup do
        ProtocolCase.setup_source()
      end
    end
  end

  def setup_source do
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    source_config = Application.get_env(:aiur, :build_data_source)
    endpoint_config = Application.get_env(:aiur, Endpoint)
    Application.put_env(:aiur, Endpoint, Keyword.merge(endpoint_config || [], server: false, dashboard_auth_required: false, secret_key_base: String.duplicate("s", 64)))
    source([])
    Aiur.TestSupport.start_owned_endpoint!()

    on_exit(fn ->
      if previous_password, do: System.put_env("AIUR_DASHBOARD_PASSWORD", previous_password), else: System.delete_env("AIUR_DASHBOARD_PASSWORD")
      restore(:build_data_source, source_config)
      restore(Endpoint, endpoint_config)
    end)

    :ok
  end

  def source(opts), do: Application.put_env(:aiur, :build_data_source, {Spy, [test_pid: self(), dataset: "live"] ++ opts})
  def build_conn, do: Phoenix.ConnTest.build_conn() |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
  def revoke_access, do: System.put_env("AIUR_DASHBOARD_PASSWORD", "revoked-test-password")
  def change(row, index \\ 7), do: %{now: 1_791_408_000_000, upsert: [row], remove: [], set: %{}, index_generation: index, resync: false}
  def data, do: elem(FixtureSource.full(dataset: "live"), 1)
  defp restore(key, nil), do: Application.delete_env(:aiur, key)
  defp restore(key, value), do: Application.put_env(:aiur, key, value)
end
