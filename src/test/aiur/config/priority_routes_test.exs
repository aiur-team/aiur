defmodule Aiur.Config.PriorityRoutesTest do
  @moduledoc """
  `agent.priority` as an ordered list of routes (#1923).

  The load-bearing cases are the ones that would let a regression through
  quietly: an existing colon-free config still meaning what it meant, a model
  alias being widened to a concrete slug *before* anything attributes cost to
  it, and a transient outage never reaching the rate-limit ledger.
  """
  use ExUnit.Case, async: true

  alias Aiur.CodingAgent
  alias Aiur.CodingAgent.{Models, RouteCredentials, RouteFailure}
  alias Aiur.Config.RoutingValue
  alias Aiur.Config.Schema.Agent, as: AgentSchema

  defp changeset(attrs), do: AgentSchema.changeset(%AgentSchema{}, attrs)

  defp priority_errors(priority) do
    changeset(%{"priority" => priority}).errors |> Keyword.get_values(:priority) |> Enum.map(&elem(&1, 0))
  end

  describe "migration: existing configs are untouched" do
    test "a colon-free priority still parses to bare backends" do
      # The operator's live config. If this ever fails, the feature has broken
      # every install that predates it.
      assert priority_errors(["deepseek", "codex", "claude"]) == []

      assert Enum.map(["deepseek", "codex", "claude"], &RoutingValue.routing_backend/1) ==
               ["deepseek", "codex", "claude"]

      assert Enum.all?(["deepseek", "codex", "claude"], &is_nil(RoutingValue.routing_model(&1)))
    end
  end

  describe "routes" do
    test "a backend:model route is accepted" do
      assert priority_errors(["claude", "openrouter:anthropic/claude-sonnet-5", "codex"]) == []
    end

    test "one model reachable two ways may appear twice" do
      # This is the whole point of the feature: duplicate *backends* are fine,
      # ordering expresses the fallback. Rejecting on backend would refuse it.
      assert priority_errors(["claude", "openrouter:anthropic/claude-sonnet-5"]) == []
      assert priority_errors(["openrouter:anthropic/claude-sonnet-5", "openrouter:anthropic/claude-opus-5"]) == []
    end

    test "duplicate routes are still rejected" do
      assert ["must not contain duplicate routes"] = priority_errors(["claude", "claude"])

      assert ["must not contain duplicate routes"] =
               priority_errors(["openrouter:anthropic/claude-opus-5", "openrouter:anthropic/claude-opus-5"])
    end

    test "an unknown backend is still rejected" do
      assert [message] = priority_errors(["not-a-backend"])
      assert message =~ "unknown backend"
    end

    test "a catalog backend with no model is a config error, not a runtime :missing_model" do
      assert [message] = priority_errors(["openrouter"])
      assert message =~ "needs an explicit model"
    end

    test "an unknown model is NOT an error: aiur's list lags the provider by design" do
      assert priority_errors(["openrouter:some-vendor/model-shipped-yesterday"]) == []
    end
  end

  describe "odd aggregator identifiers" do
    test "a ~-prefixed model is rejected explicitly rather than parsing into something surprising" do
      assert [message] = priority_errors(["openrouter:~moonshotai/kimi-latest"])
      assert message =~ "starts with `~`"
    end

    test "a :batch suffix cannot masquerade as a reasoning effort" do
      # `openrouter:moonshotai/kimi-k2.7-code:batch` splits into
      # {backend, model, effort}, so `batch` lands in the effort slot. OpenRouter
      # declares no efforts, so it is rejected with a message naming the effort
      # rather than silently sending a `:batch` model or dropping the suffix.
      assert [message] = priority_errors(["openrouter:moonshotai/kimi-k2.7-code:batch"])
      assert message =~ "batch"
    end
  end

  describe "short aliases" do
    test "openrouter:claude resolves to a concrete slug" do
      assert "claude" in CodingAgent.model_aliases("openrouter")
      assert CodingAgent.resolve_model("openrouter", "claude") =~ ~r{^anthropic/claude-}
    end

    test "a pinned slug is passed through untouched" do
      assert CodingAgent.resolve_model("openrouter", "anthropic/claude-opus-5") == "anthropic/claude-opus-5"
    end

    test "an alias claimed by two vendors is a config error, not a coin flip" do
      assert Models.ambiguous_alias?(["anthropic/claude-opus-5", "bootleg/claude-opus-5"], "claude")
      refute Models.ambiguous_alias?(["anthropic/claude-opus-5", "anthropic/claude-sonnet-5"], "claude")
    end

    test "alias resolution runs BEFORE cost attribution" do
      # The ordering guard. Attribution keys the price table on the model
      # string; the alias `claude` is not a price-table identity and never can
      # be, so if resolution ever moved after attribution every aliased call
      # would silently report as unpriced. Asserting that the string handed to
      # the transport is already concrete is what fails if that order flips.
      issue = %Aiur.Issue{identifier: "T-1", selected_backend: "openrouter", selected_model: "claude"}

      assert CodingAgent.model_for(issue) == "claude"

      resolved = CodingAgent.resolve_model(CodingAgent.backend_for(issue), CodingAgent.model_for(issue))

      refute resolved == "claude"
      assert resolved in CodingAgent.models("openrouter")
    end
  end

  describe "route persistence" do
    test "selection persists both halves of the route" do
      issue = %Aiur.Issue{identifier: "T-2"}

      {:ok, selected} =
        CodingAgent.select_for_dispatch(issue,
          backends: ["openrouter:anthropic/claude-opus-5"],
          configured_backends: ["openrouter"],
          api_key_fetcher: fn _ -> "key" end,
          state: %{"backends" => %{}}
        )

      assert selected.selected_backend == "openrouter"
      assert selected.selected_model == "anthropic/claude-opus-5"
    end

    test "the persisted model wins over routing at session start" do
      # Without this, dispatch picks a route and session start-up re-resolves a
      # different model, so the operator's ordering silently does nothing.
      issue = %Aiur.Issue{identifier: "T-3", selected_backend: "openrouter", selected_model: "anthropic/claude-opus-5"}

      assert CodingAgent.model_for(issue) == "anthropic/claude-opus-5"
    end
  end

  describe "credentials" do
    test "a route with no key is skipped at selection, and the next one is used" do
      issue = %Aiur.Issue{identifier: "T-4"}

      fetcher = fn
        "OPENROUTER_API_KEY" -> "key"
        _ -> nil
      end

      {:ok, selected} =
        CodingAgent.select_for_dispatch(issue,
          backends: ["deepseek", "openrouter:anthropic/claude-opus-5"],
          configured_backends: ["deepseek", "openrouter"],
          api_key_fetcher: fetcher,
          state: %{"backends" => %{}}
        )

      assert selected.selected_backend == "openrouter"
    end

    test "a backend authenticating through its own CLI is never skipped for a missing env var" do
      assert RouteCredentials.usable?("claude", api_key_fetcher: fn _ -> nil end)
      assert RouteCredentials.usable?("codex", api_key_fetcher: fn _ -> nil end)
    end

    test "every route key-less is a hard error, not a silently empty fleet" do
      assert_raise ArgumentError, ~r/no agent can be dispatched/, fn ->
        RouteCredentials.verify_any_usable!(["deepseek", "openrouter:anthropic/claude-opus-5"],
          api_key_fetcher: fn _ -> nil end
        )
      end
    end
  end

  describe "failure semantics" do
    test "429 advances and is recorded" do
      assert RouteFailure.classify(:rate_limited) == :usage_limit
      assert RouteFailure.advance?(:usage_limit)
      assert RouteFailure.record_limit?(:usage_limit)
    end

    test "a transient outage advances for this claim but is NEVER written to the limit ledger" do
      # The conflation that would hide an outage: model-usage.json means
      # "rate-limited until reset_at", so an outage recorded there becomes
      # indistinguishable from a quota event and suppresses its own alert.
      for reason <- [:invalid_response, {:http_error, 503, "boom"}, :timeout] do
        assert RouteFailure.classify(reason) == :transient
      end

      assert RouteFailure.advance?(:transient)
      refute RouteFailure.record_limit?(:transient)
    end

    test "401 does NOT advance: a broken credential must surface, not reroute spend" do
      assert RouteFailure.classify(:unauthorized) == :auth_rejected
      refute RouteFailure.advance?(:auth_rejected)
      refute RouteFailure.record_limit?(:auth_rejected)
    end
  end

  describe "ledger keying" do
    test "every openrouter route shares one account entry" do
      assert Aiur.ModelAvailability.backend_key("openrouter:anthropic/claude-opus-5") ==
               Aiur.ModelAvailability.backend_key("openrouter:deepseek/deepseek-v4-flash")
    end

    test "a direct 429 does not mark the via-OpenRouter route limited" do
      refute Aiur.ModelAvailability.backend_key("claude") ==
               Aiur.ModelAvailability.backend_key("openrouter:anthropic/claude-sonnet-5")
    end
  end

  describe "pricing policy (shape only; #1456 supplies the behaviour)" do
    test "routing away from peak pricing is the default" do
      assert %{avoid_peak_pricing: true} = changeset(%{}) |> Ecto.Changeset.apply_changes() |> Map.get(:pricing_policy)
    end

    test "it can be turned off" do
      policy =
        %{"pricing_policy" => %{"avoid_peak_pricing" => false}}
        |> changeset()
        |> Ecto.Changeset.apply_changes()
        |> Map.get(:pricing_policy)

      assert %{avoid_peak_pricing: false} = policy
    end
  end

  describe "selection-time policy seam (#1456 plugs in here)" do
    test "priority is reduced through policies per claim, not read as a fixed literal" do
      issue = %Aiur.Issue{identifier: "T-5"}
      drop_deepseek = fn routes -> Enum.reject(routes, &(RoutingValue.routing_backend(&1) == "deepseek")) end

      {:ok, selected} =
        CodingAgent.select_for_dispatch(issue,
          backends: ["deepseek", "openrouter:anthropic/claude-opus-5"],
          configured_backends: ["deepseek", "openrouter"],
          api_key_fetcher: fn _ -> "key" end,
          route_policies: [drop_deepseek],
          state: %{"backends" => %{}}
        )

      assert selected.selected_backend == "openrouter"
    end

    test "a route resolves to the price identity it bills under, without dispatching" do
      # A cost-aware policy has to compare candidates before the request, so the
      # billing identity must be a pure function of the route. The provider is
      # the billing path, never the upstream that ends up serving it.
      assert %{provider: :openrouter, model: "anthropic/claude-opus-5"} =
               CodingAgent.route_price_identity("openrouter:anthropic/claude-opus-5")
    end
  end

  describe "avoid_peak_pricing routing policy (#1456 behaviour)" do
    # Pinned clock instants — the policy never reads the real clock in tests.
    @peak_weekday_now ~U[2026-08-24 02:00:00Z]
    @off_peak_weekday_now ~U[2026-08-24 12:00:00Z]
    @weekend_off_peak_now ~U[2026-08-29 02:00:00Z]

    defp dispatch_issue(opts) do
      issue = %Aiur.Issue{identifier: "T-9"}

      CodingAgent.select_for_dispatch(
        issue,
        Keyword.merge(
          [
            backends: ["deepseek", "openrouter:anthropic/claude-opus-5"],
            configured_backends: ["deepseek", "openrouter"],
            api_key_fetcher: fn _ -> "key" end,
            state: %{"backends" => %{}}
          ],
          opts
        )
      )
    end

    test "avoid_peak_pricing true skips a peak-priced route and falls through to the next priority entry" do
      assert {:ok, %Aiur.Issue{selected_backend: "openrouter"}} =
               dispatch_issue(avoid_peak_pricing: true, now: @peak_weekday_now)
    end

    test "avoid_peak_pricing true keeps the route while off-peak (including weekends)" do
      assert {:ok, %Aiur.Issue{selected_backend: "deepseek"}} =
               dispatch_issue(avoid_peak_pricing: true, now: @off_peak_weekday_now)

      assert {:ok, %Aiur.Issue{selected_backend: "deepseek"}} =
               dispatch_issue(avoid_peak_pricing: true, now: @weekend_off_peak_now)
    end

    test "avoid_peak_pricing false uses agent.priority exactly as written, even at peak" do
      assert {:ok, %Aiur.Issue{selected_backend: "deepseek"}} =
               dispatch_issue(avoid_peak_pricing: false, now: @peak_weekday_now)
    end

    test "an unknown or unparseable window fails toward NOT rerouting" do
      # A malformed schedule (as if the hand-maintained table were broken)
      # classifies as :unknown; the route is kept and agent.priority is used
      # exactly as written.
      malformed = fn
        :deepseek -> %{utc_offset_hours: 8}
        _provider -> nil
      end

      assert {:ok, %Aiur.Issue{selected_backend: "deepseek"}} =
               dispatch_issue(
                 avoid_peak_pricing: true,
                 now: @peak_weekday_now,
                 window_schedule_for: malformed
               )
    end

    test "peak_priced_route?/2 is false for providers with no windowed schedule" do
      assert CodingAgent.peak_priced_route?("openrouter:anthropic/claude-opus-5", @peak_weekday_now) == false
    end
  end
end
