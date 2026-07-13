defmodule Aiur.GitHub.ErrorsTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.Errors

  test "classifies transport failures" do
    assert Errors.classify_error({:error, :nxdomain}) == {:github, :dns, %{reason: :nxdomain}}
    assert Errors.classify_error({:error, :timeout}) == {:github, :timeout, %{reason: :timeout}}

    assert Errors.classify_error({:error, {:tls_alert, :handshake_failure}}) ==
             {:github, :tls, %{reason: {:tls_alert, :handshake_failure}}}

    assert Errors.classify_error({:error, :other}) == {:github, :transport, %{reason: :other}}
  end

  test "classifies proactive budget deferral as rate limited" do
    assert {:github, :rate_limited, %{reason: :github_rate_budget_deferred, retry_after: 2}} =
             Errors.classify_error({:error, {:github_rate_budget_deferred, 1_001}})
  end

  test "classifies HTTP auth, rate-limit, and generic statuses" do
    assert Errors.classify_error(%{status: 401, body: %{"message" => "Bad credentials"}}) ==
             {:github, :auth, %{status: 401, message: "Bad credentials"}}

    response = %{status: 403, headers: [{"x-ratelimit-remaining", "0"}, {"retry-after", "7"}]}

    assert Errors.classify_error(response) ==
             {:github, :rate_limited, %{status: 403, retry_after: 7, poll_interval: nil}}

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

  test "identifies retryable GitHub errors" do
    assert Errors.retryable_github_error?({:github, :dns, %{}})
    assert Errors.retryable_github_error?({:github, :rate_limited, %{}})
    refute Errors.retryable_github_error?({:github, :auth, %{}})
    refute Errors.retryable_github_error?(:other)
  end
end
