defmodule Aiur.Usage.Headless.FakeRegistryAdapterTest do
  use ExUnit.Case, async: true

  alias Aiur.Usage.Headless.{Catalog, Context, Normalizer}

  test "a test-only backend meters through its registry adapter" do
    context = %Context{
      run_id: "run-fake",
      agent_family: :fake,
      backend: :app_server,
      transport: :app_server,
      account_generation: %{provider: :fake, backend: :app_server, generation: "fake-generation", freshness: :current, health: :healthy, reason: nil},
      source_sequence: 1,
      resolved_model: "fake-1"
    }

    assert Catalog.adapters_for(:fake) == [Aiur.Usage.Headless.Fake.RequestUsage]

    assert %{coverages: [], envelopes: [envelope]} =
             Normalizer.normalize(
               %{"fake_input_tokens" => 7, "request_id" => "fake-request-1"},
               nil,
               context,
               ~U[2026-07-31 12:00:00Z]
             )

    assert envelope.provider == :fake
    assert envelope.tokens.input == 7
    assert envelope.relationship_revision == "fake-app-server-1"
  end
end
