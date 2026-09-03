defmodule Aiur.GitHub.CredentialSelectorTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.{Budget, Credential, CredentialRegistry, CredentialSelector, Transport}

  @now ~U[2026-08-20 12:00:00Z]

  # The env var name is unique per credential, not per id. These tests are
  # async and the process environment is global: a fixed name like
  # `TOKEN_PRIMARY` is shared with every other test in this file and with
  # `CredentialUsageTest`, so one test's `on_exit` cleanup can delete the
  # variable another test is mid-way through reading. An unresolvable token
  # collapses `token_key/1` to nil, which silently makes two credentials look
  # like one.
  defp credential(id, attrs) do
    env = "AIUR_TEST_TOKEN_#{String.upcase(id)}_#{System.unique_integer([:positive])}"

    struct!(%Credential{id: id, kind: :machine_user, identity: id, token_env: env}, attrs)
  end

  defp with_token(credential, token) do
    System.put_env(credential.token_env, token)
    on_exit(fn -> System.delete_env(credential.token_env) end)
    credential
  end

  defp window(remaining, limit \\ 5_000) do
    %{limit: limit, remaining: remaining, used: limit - remaining, reset_at: DateTime.add(@now, 600), observed_at: @now}
  end

  describe "single credential (back-compat)" do
    test "one configured credential keeps its token and receives a stable accounting key" do
      only = with_token(credential("solo", primary?: true, writes?: true), "solo-token")

      refute CredentialRegistry.pooled?(credentials: [only])

      request = %{method: :get, url: "https://api.github.com/repos/o/r", token: "solo-token"}

      assigned = CredentialSelector.assign(request, credentials: [only])

      assert assigned.token == request.token
      assert assigned.credential_key == Credential.token_key(only)
      refute Map.has_key?(assigned, :credential_id)
    end

    test "choose/3 returns the only credential for both budgets and both intents" do
      only = with_token(credential("solo", primary?: true, writes?: true), "solo-token")
      opts = [credentials: [only], now: @now]

      for resource <- ["core", "graphql"], intent <- [:read, :write] do
        assert %Credential{id: "solo"} = CredentialSelector.choose(resource, intent, opts)
      end
    end

    test "a request with no token is untouched" do
      assert CredentialSelector.assign(%{method: :get}) == %{method: :get}
    end
  end

  describe "headroom selection" do
    setup do
      primary = with_token(credential("primary", primary?: true, writes?: true), "primary-token")
      spare = with_token(credential("spare", writes?: true), "spare-token")
      %{primary: primary, spare: spare}
    end

    test "picks the credential with the most remaining budget", %{primary: primary, spare: spare} do
      windows = %{
        Credential.token_key(primary) => %{"graphql" => window(100)},
        Credential.token_key(spare) => %{"graphql" => window(4_000)}
      }

      assert %Credential{id: "spare"} =
               CredentialSelector.choose("graphql", :read, credentials: [primary, spare], windows: windows, now: @now)
    end

    test "core and graphql select independently", %{primary: primary, spare: spare} do
      windows = %{
        Credential.token_key(primary) => %{"core" => window(4_900), "graphql" => window(10)},
        Credential.token_key(spare) => %{"core" => window(50), "graphql" => window(4_000)}
      }

      opts = [credentials: [primary, spare], windows: windows, now: @now]

      assert %Credential{id: "primary"} = CredentialSelector.choose("core", :read, opts)
      assert %Credential{id: "spare"} = CredentialSelector.choose("graphql", :read, opts)
    end

    test "an unobserved credential outranks an observed depleted one", %{primary: primary, spare: spare} do
      windows = %{Credential.token_key(primary) => %{"graphql" => window(120)}}

      assert %Credential{id: "spare"} =
               CredentialSelector.choose("graphql", :read, credentials: [primary, spare], windows: windows, now: @now)
    end

    test "a credential with remaining 0 is skipped", %{primary: primary, spare: spare} do
      windows = %{
        Credential.token_key(primary) => %{"graphql" => window(0)},
        Credential.token_key(spare) => %{"graphql" => window(5)}
      }

      assert %Credential{id: "spare"} =
               CredentialSelector.choose("graphql", :read, credentials: [primary, spare], windows: windows, now: @now)
    end

    test "when every credential reads exhausted the primary is used anyway", %{primary: primary, spare: spare} do
      windows = %{
        Credential.token_key(primary) => %{"graphql" => window(0)},
        Credential.token_key(spare) => %{"graphql" => window(0)}
      }

      assert %Credential{id: "primary"} =
               CredentialSelector.choose("graphql", :read, credentials: [primary, spare], windows: windows, now: @now)
    end

    test "ties resolve to the primary", %{primary: primary, spare: spare} do
      windows = %{
        Credential.token_key(primary) => %{"core" => window(2_000)},
        Credential.token_key(spare) => %{"core" => window(2_000)}
      }

      assert %Credential{id: "primary"} =
               CredentialSelector.choose("core", :read, credentials: [primary, spare], windows: windows, now: @now)
    end
  end

  describe "write isolation" do
    setup do
      primary = with_token(credential("primary", primary?: true, writes?: true), "primary-token")
      human = with_token(credential("human", kind: :human), "human-token")
      %{primary: primary, human: human}
    end

    test "a human credential never carries a write even with all the headroom", %{primary: primary, human: human} do
      windows = %{
        Credential.token_key(primary) => %{"core" => window(1)},
        Credential.token_key(human) => %{"core" => window(5_000)}
      }

      assert %Credential{id: "primary"} =
               CredentialSelector.choose("core", :write, credentials: [primary, human], windows: windows, now: @now)
    end

    test "a human credential does carry reads", %{primary: primary, human: human} do
      windows = %{
        Credential.token_key(primary) => %{"core" => window(1)},
        Credential.token_key(human) => %{"core" => window(5_000)}
      }

      assert %Credential{id: "human"} =
               CredentialSelector.choose("core", :read, credentials: [primary, human], windows: windows, now: @now)
    end

    test "eligible?/2 refuses writes on a human credential regardless of the writes flag" do
      refute Credential.eligible?(%Credential{id: "h", kind: :human, writes?: true}, :write)
    end
  end

  # The exhausted-credential fallback used to hand back whatever the registry
  # listed first, without checking it could carry the intent. That is normally
  # the legacy credential, which is write-eligible — but when the legacy
  # credential does not resolve it drops out of the list, and first place can
  # fall to a human. Every other guard holds; this route went around them.
  describe "the exhausted fallback" do
    setup do
      # Deliberately never exported, so the registry filters it out and no
      # `primary?` credential survives.
      legacy = %Credential{id: "primary", kind: :machine_user, source: :env, token_env: "AIUR_TEST_LEGACY_ABSENT", writes?: true, primary?: true}
      human = with_token(credential("human_first", kind: :human), "human-first-token")

      # Two write-eligible machine users, not one. With a single eligible
      # credential `choose/3` short-circuits on its `[only]` clause and never
      # reaches the fallback under test — the fixture has to get past that to
      # exercise the rule it exists to protect.
      machine_a = with_token(credential("machine_a", writes?: true), "machine-a-token")
      machine_b = with_token(credential("machine_b", writes?: true), "machine-b-token")

      # Human ordered ahead of the machine users so `List.first/1` picks it once
      # the unresolvable legacy credential drops out.
      credentials = [legacy, human, machine_a, machine_b]

      # Both write-eligible credentials observed exhausted; the human has room.
      windows = %{
        Credential.token_key(machine_a) => %{"core" => window(0)},
        Credential.token_key(machine_b) => %{"core" => window(0)},
        Credential.token_key(human) => %{"core" => window(5_000)}
      }

      %{credentials: credentials, human: human, windows: windows}
    end

    test "never returns a human credential for a write", context do
      %{credentials: credentials, human: human, windows: windows} = context

      opts = [credentials: credentials, windows: windows, now: @now]

      assert CredentialSelector.choose("core", :write, opts) != human
      refute match?(%Credential{kind: :human}, CredentialSelector.choose("core", :write, opts))
    end

    test "a real write request is never assigned a human token", context do
      %{credentials: credentials, windows: windows} = context

      request = %{method: :post, url: "https://api.github.com/repos/o/r/issues/1/comments", body: %{body: "hi"}, token: "config-token"}

      assigned = CredentialSelector.assign(request, credentials: credentials, windows: windows, now: @now)

      refute assigned.token == "human-first-token"
    end

    # With no eligible credential left, refusing to choose is the right
    # answer: the request keeps the token it arrived with, which is
    # `Config.token/0`. A write that cannot be attributed safely must not be
    # attributed at all.
    test "returns nil rather than an ineligible credential when only a human resolves", %{human: human} do
      legacy = %Credential{id: "primary", kind: :machine_user, source: :env, token_env: "AIUR_TEST_LEGACY_ABSENT", writes?: true, primary?: true}

      opts = [credentials: [legacy, human], windows: %{}, now: @now]

      assert CredentialSelector.choose("core", :write, opts) == nil
    end

    test "the request keeps its original token when nothing may carry the write", %{human: human} do
      legacy = %Credential{id: "primary", kind: :machine_user, source: :env, token_env: "AIUR_TEST_LEGACY_ABSENT", writes?: true, primary?: true}

      request = %{method: :post, url: "https://api.github.com/repos/o/r/labels", body: %{name: "x"}, token: "config-token"}

      assigned = CredentialSelector.assign(request, credentials: [legacy, human], windows: %{}, now: @now)

      assert assigned.token == "config-token"
      refute Map.has_key?(assigned, :credential_id)
    end

    # Reads are unaffected: every credential is read-eligible, so the human
    # may still absorb read traffic, which is the entire point of the pool.
    test "reads still use the human credential", context do
      %{credentials: credentials, human: human} = context

      assert CredentialSelector.choose("core", :read, credentials: credentials, windows: %{}, now: @now) == human
    end
  end

  describe "intent/1" do
    test "REST GET is a read" do
      assert CredentialSelector.intent(%{method: :get, url: "https://api.github.com/repos/o/r"}) == :read
    end

    test "REST POST, PATCH and DELETE are writes" do
      for method <- [:post, :patch, :delete] do
        assert CredentialSelector.intent(%{method: method, url: "https://api.github.com/repos/o/r/labels"}) == :write
      end
    end

    test "a GraphQL query is a read" do
      request = %{method: :post, url: Transport.graphql_url(), body: %{query: "query($n: Int!) { rateLimit { cost } }"}}

      assert CredentialSelector.intent(request) == :read
    end

    test "a GraphQL mutation is a write" do
      request = %{method: :post, url: Transport.graphql_url(), body: %{query: "mutation AddComment($id: ID!) { addComment { clientMutationId } }"}}

      assert CredentialSelector.intent(request) == :write
    end

    test "a GraphQL request with an unreadable body is treated as a write" do
      request = %{method: :post, url: Transport.graphql_url(), body: %{}}

      assert CredentialSelector.intent(request) == :write
    end
  end

  describe "assign/2" do
    test "keeps a credential-pinned request on its supplied token" do
      primary = with_token(credential("primary", primary?: true, writes?: true), "ghp_primary-token")
      spare = with_token(credential("spare", writes?: true), "github_pat_spare-token")
      windows = %{Credential.token_key(primary) => %{"core" => window(1)}}

      request = %{
        method: :get,
        url: "https://api.github.com/repos/o/r",
        token: "ghp_primary-token",
        credential_pinned?: true
      }

      assert CredentialSelector.assign(request, credentials: [primary, spare], windows: windows, now: @now) == request
    end

    test "swaps in the selected credential's token and records which one" do
      primary = with_token(credential("primary", primary?: true, writes?: true), "primary-token")
      spare = with_token(credential("spare", writes?: true), "spare-token")

      windows = %{Credential.token_key(primary) => %{"core" => window(1)}}

      request = %{method: :get, url: "https://api.github.com/repos/o/r", token: "primary-token"}

      assigned = CredentialSelector.assign(request, credentials: [primary, spare], windows: windows, now: @now)

      assert assigned.token == "spare-token"
      assert assigned.credential_id == "spare"
      assert assigned.credential_key == Credential.token_key(spare)
    end

    test "attaches one stable key to successive tokens for the same credential" do
      credential = credential("rotating", identity: "Aiur-Bot", primary?: true, writes?: true)
      first = with_token(credential, "first-token")
      first_request = CredentialSelector.assign(%{method: :get, url: "https://api.github.com/repos/o/r", token: "first-token"}, credentials: [first])

      System.put_env(first.token_env, "second-token")
      second_request = CredentialSelector.assign(%{method: :get, url: "https://api.github.com/repos/o/r", token: "second-token"}, credentials: [first])

      assert first_request.credential_key == second_request.credential_key
      refute first_request.credential_key == Budget.token_key("first-token")
    end

    test "distinct configured credentials stay distinct when identity and token overlap" do
      first = with_token(credential("first", identity: "same-login"), "shared-token")
      second = with_token(credential("second", identity: "same-login"), "shared-token")

      refute Credential.token_key(first) == Credential.token_key(second)
    end
  end
end
