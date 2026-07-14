defmodule Aiur.BuildOrder.ProviderResultTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.{Diagnostic, ProviderResult}

  test "complete results retain bounded safe request observations" do
    result =
      ProviderResult.complete(:catalog,
        calls: 2,
        pages: 2,
        rate_limit: %{remaining: 99, reset_at: "2026-07-13T12:00:00Z", secret: "nope"}
      )

    assert ProviderResult.complete?(result)
    assert result.candidate == :catalog
    assert result.calls == 2
    assert result.pages == 2
    assert result.rate_limit == %{remaining: 99, reset_at: "2026-07-13T12:00:00Z"}
  end

  test "failed results redact raw provider detail while preserving retry information" do
    result =
      ProviderResult.failed({:github, :rate_limited, %{status: 429, retry_after: 30, token: "secret"}},
        calls: 4,
        pages: 3,
        diagnostics: [Diagnostic.new(:call_budget_exhausted)]
      )

    refute ProviderResult.complete?(result)
    assert result.error == {:github, :rate_limited, %{status: 429, retry_after: 30}}
    assert result.calls == 4
    assert result.pages == 3
    assert [%{code: :call_budget_exhausted}] = result.diagnostics
  end

  test "GraphQL errors become a controlled failure category" do
    result = ProviderResult.failed({:github_graphql_errors, [%{"message" => "private body"}]})

    assert result.error == :graphql_partial
    assert [%{code: :provider_unavailable}] = result.diagnostics
  end

  test "malformed provider response shapes become a schema category" do
    assert ProviderResult.failed(:invalid_connection).error == :schema
    assert ProviderResult.failed(:invalid_root).error == :schema
    assert ProviderResult.failed(:invalid_graphql_response).error == :schema
  end

  test "caller validation failures retain their local taxonomy" do
    assert ProviderResult.failed(:invalid_requested_root).error == :invalid_requested_root
  end
end
