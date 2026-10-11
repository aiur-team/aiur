defmodule AiurWeb.Build.FixtureUsageTest do
  use Aiur.TestSupport
  alias Aiur.TestSupport.BuildHome.FixtureSource
  alias AiurWeb.Build.Read
  alias AiurWeb.Endpoint

  setup do
    before_dataset = Application.get_env(:aiur, :build_fixture_dataset)
    before_endpoint = Application.get_env(:aiur, Endpoint)

    on_exit(fn ->
      if before_dataset, do: Application.put_env(:aiur, :build_fixture_dataset, before_dataset), else: Application.delete_env(:aiur, :build_fixture_dataset)
      if before_endpoint, do: Application.put_env(:aiur, Endpoint, before_endpoint), else: Application.delete_env(:aiur, Endpoint)
    end)

    :ok
  end

  test "configured quota source preserves the selected frozen dataset across reloads" do
    assert FixtureSource.configure_usage(:ok) == :ok
    source = Application.fetch_env!(:aiur, Endpoint)[:build_usage_source]

    for dataset <- ~w(live dense newrepo noqueue offline) do
      Application.put_env(:aiur, :build_fixture_dataset, dataset)
      {:ok, snapshot} = FixtureSource.snapshot(financial: {:ok, nil})
      assert source.read({:ok, nil}, []) == snapshot["usage"]
      assert source.read({:ok, nil}, reload: {AiurWeb.FinancialData, :updated, :identity}) == snapshot["usage"]
    end

    for dataset <- ~w(unavailable hold) do
      Application.put_env(:aiur, :build_fixture_dataset, dataset)
      assert source.read(:locked) == Read.locked_usage()
      assert source.read({:ok, nil}) == %{"state" => "unavailable", "observed_at" => nil, "reason" => "fixture_unavailable"}
    end
  end
end
