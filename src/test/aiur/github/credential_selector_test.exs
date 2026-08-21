defmodule Aiur.GitHub.CredentialSelectorTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.{Budget, Credential, CredentialRegistry, CredentialSelector, Transport}

  @now ~U[2026-08-20 12:00:00Z]

  defp credential(id, attrs) do
    struct!(
      %Credential{id: id, kind: :machine_user, identity: id, token_env: "TOKEN_#{String.upcase(id)}"},
      attrs
    )
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
    test "one configured credential is not pooled and assign/2 leaves the request alone" do
      only = with_token(credential("solo", primary?: true, writes?: true), "solo-token")

      refute CredentialRegistry.pooled?(credentials: [only])

      request = %{method: :get, url: "https://api.github.com/repos/o/r", token: "legacy-token"}

      assert CredentialSelector.assign(request, credentials: [only]) == request
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
    test "swaps in the selected credential's token and records which one" do
      primary = with_token(credential("primary", primary?: true, writes?: true), "primary-token")
      spare = with_token(credential("spare", writes?: true), "spare-token")

      windows = %{Credential.token_key(primary) => %{"core" => window(1)}}

      request = %{method: :get, url: "https://api.github.com/repos/o/r", token: "primary-token"}

      assigned = CredentialSelector.assign(request, credentials: [primary, spare], windows: windows, now: @now)

      assert assigned.token == "spare-token"
      assert assigned.credential_id == "spare"
      assert Budget.token_key(assigned.token) == Credential.token_key(spare)
    end
  end
end
