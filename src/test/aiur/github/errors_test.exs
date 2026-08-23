defmodule Aiur.GitHub.ErrorsTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.Errors

  test "classifies transport failures" do
    assert Errors.classify_error({:error, :nxdomain}) == {:github, :dns, %{reason: :nxdomain}}
    assert Errors.classify_error({:error, :timeout}) == {:github, :timeout, %{reason: :timeout}}

    assert Errors.classify_error({:error, {:tls_alert, :handshake_failure}}) ==
             {:github, :tls, %{reason: {:tls_alert, :handshake_failure}}}

    assert Errors.classify_error({:error, :other}) == {:github, :transport, %{reason: :other}}

    # #2427: the budget broker distinguishes a timeout from a malformed reply,
    # and the transport taxonomy must keep them apart — a broker timeout is a
    # `:timeout` (transient), a malformed reply stays `:transport` with its
    # distinctive reason so the shared classifier can treat it as permanent.
    assert Errors.classify_error({:error, :github_budget_broker_timeout}) ==
             {:github, :timeout, %{reason: :github_budget_broker_timeout}}

    assert Errors.classify_error({:error, :github_budget_broker_unavailable}) ==
             {:github, :transport, %{reason: :github_budget_broker_unavailable}}
  end

  test "classifies HTTP auth, rate-limit, and generic statuses" do
    assert Errors.classify_error(%{status: 401, body: %{"message" => "Bad credentials"}}) ==
             {:github, :auth, %{status: 401, message: "Bad credentials"}}

    response = %{status: 403, headers: [{"x-ratelimit-remaining", "0"}, {"retry-after", "7"}]}

    assert Errors.classify_error(response) ==
             {:github, :rate_limited, %{status: 403, remaining: 0, retry_after: 7, poll_interval: nil, reset_at: nil}}

    assert Errors.classify_error(%{status: 500}) == {:github, :http, %{status: 500}}
  end

  test "extracts rate-limit signals" do
    response = %{
      status: 200,
      headers: [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", "1"}],
      body: %{"resources" => %{"core" => %{"remaining" => 0}}}
    }

    assert Errors.rate_limited_response?(response, :rate_limit)
    assert Errors.rate_limit_remaining(response) == 0
    assert Errors.rate_limit_reset(response) == "1970-01-01T00:00:01Z"
    assert Errors.rate_limit_body_remaining(response) == 0
    assert Errors.rate_limit_message?(%{"message" => "API rate limit exceeded"})
  end

  test "classifies typed GraphQL rate-limit and permission errors before partials" do
    rate_limited = %{
      status: 200,
      headers: [{"x-ratelimit-remaining", "8"}, {"x-ratelimit-reset", "1"}],
      body: %{"errors" => [%{"type" => "RATE_LIMITED", "message" => "query quota exhausted"}]}
    }

    assert Errors.graphql_error(rate_limited) ==
             {:github, :rate_limited, %{status: 200, remaining: 8, reset_at: "1970-01-01T00:00:01Z"}}

    permission_denied = %{
      status: 200,
      headers: [{"x-ratelimit-remaining", "7"}, {"x-ratelimit-reset", "1"}],
      body: %{
        "errors" => [
          %{
            "extensions" => %{"code" => "FORBIDDEN"},
            "message" => "query access denied"
          }
        ]
      }
    }

    assert Errors.graphql_error(permission_denied) ==
             {:github, :permission, %{status: 200, remaining: 7, reset_at: "1970-01-01T00:00:01Z"}}

    message_only_rate_limit = %{
      status: 200,
      body: %{"errors" => [%{"message" => "API rate limit exceeded"}]}
    }

    assert Errors.graphql_error(message_only_rate_limit) == {:github, :rate_limited, %{status: 200}}

    assert Errors.graphql_error(%{status: 200, body: %{"errors" => [%{"type" => "RATE_LIMITED"}]}}) ==
             {:github, :rate_limited, %{status: 200}}

    assert Errors.graphql_error(%{status: 200, body: %{"errors" => [%{"code" => "RATE_LIMITED"}]}}) ==
             {:github, :rate_limited, %{status: 200}}

    assert Errors.graphql_error(%{
             status: 200,
             body: %{"errors" => [%{"type" => "FORBIDDEN"}, %{"type" => "RATE_LIMITED"}]}
           }) == {:github, :rate_limited, %{status: 200}}

    assert Errors.graphql_error(%{status: 200, body: %{"errors" => [%{"extensions" => "malformed"}]}}) ==
             :graphql_partial

    assert Errors.graphql_error(%{status: 200, body: %{"errors" => [%{"message" => "internal failure"}]}}) ==
             :graphql_partial
  end

  test "identifies retryable GitHub errors" do
    assert Errors.retryable_github_error?({:github, :dns, %{}})
    assert Errors.retryable_github_error?({:github, :timeout, %{}})
    assert Errors.retryable_github_error?({:github, :transport, %{reason: :closed}})
    assert Errors.retryable_github_error?({:github, :rate_limited, %{}})
    assert Errors.retryable_github_error?({:github, :http, %{status: 500}})
    refute Errors.retryable_github_error?({:github, :auth, %{}})
    refute Errors.retryable_github_error?({:github, :http, %{status: 403}})
    refute Errors.retryable_github_error?(:other)

    # #2427: a budget-broker *timeout* is transient, but a *malformed reply*
    # (broker unavailable) is a bug — retrying it wastes the budget and hides
    # the defect. Pin the specific atoms, since a test asserting only "some
    # error was returned" passes against the old catch-all that classified both
    # as retryable `:transport`.
    assert Errors.retryable_github_error?(Errors.classify_error({:error, :github_budget_broker_timeout}))
    refute Errors.retryable_github_error?(Errors.classify_error({:error, :github_budget_broker_unavailable}))
  end
end
