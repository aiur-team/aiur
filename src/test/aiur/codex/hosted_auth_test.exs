defmodule Aiur.Codex.HostedAuthTest do
  use ExUnit.Case, async: false

  import Aiur.Codex.AccountGenerationTestSupport
  import Aiur.Codex.TurnLoopTestSupport, only: [base_state: 0, close_port: 1, open_cat_port: 0]

  alias Aiur.Codex.{AccountGeneration, Notifications}
  alias Aiur.ProviderAccountGeneration

  setup do
    owner = start_owner(mint: sequence_mint())
    session = owner |> session_for() |> Map.put(:instance_mode, "hosted")
    %{owner: owner, session: session}
  end

  test "hosted startup accepts only the Codex API-key observation", %{owner: owner, session: session} do
    assert :ok = AccountGeneration.seed_from_account_read(session, %{auth_mode: "apikey"})

    assert %{generation: generation, freshness: :current, health: :healthy} =
             ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)

    assert is_binary(generation)

    for {auth_mode, auth_class} <- [
          {"chatgpt", :subscription},
          {"chatgptAuthTokens", :oauth},
          {"personalAccessToken", :personal_token},
          {"headers", :headers},
          {"agentIdentity", :agent_identity},
          {"bedrockApiKey", :bedrock}
        ] do
      candidate = owner |> session_for() |> Map.put(:instance_mode, "hosted")

      assert AccountGeneration.seed_from_account_read(candidate, %{auth_mode: auth_mode}) ==
               {:error, {:unsafe_hosted_authentication, "codex", auth_class}}

      assert %{generation: nil} =
               ProviderAccountGeneration.lookup(owner, :codex, :app_server, candidate.account_generation_binding)
    end

    unknown = owner |> session_for() |> Map.put(:instance_mode, "hosted")

    assert AccountGeneration.seed_from_account_read(unknown, %{auth_mode: "future-mode"}) ==
             {:error, {:unsafe_hosted_authentication, "codex", :unknown}}
  end

  test "an unsafe hosted account transition returns only redacted terminal evidence", %{owner: owner, session: session} do
    secret = "person@example.test credential=super-secret"
    assert :ok = AccountGeneration.seed_from_account_read(session, %{auth_mode: "apikey"})

    payload = %{
      "method" => "account/updated",
      "params" => %{"authMode" => "chatgpt", "email" => secret, "credential" => secret}
    }

    assert {:refused, {:unsafe_hosted_authentication, "codex", :subscription}, details} =
             AccountGeneration.handle_notification(session, "account/updated", payload)

    assert details == %{payload: %{"method" => "provider_account/authentication_changed", "params" => %{}}, raw: nil}
    Aiur.TestSupport.refute_leak(details, secret)

    assert %{generation: nil} =
             ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)
  end

  test "a rejected account notification terminates the Codex turn" do
    owner = start_owner(mint: sequence_mint())
    port = open_cat_port()

    on_exit(fn ->
      close_port(port)
      Aiur.TestSupport.safe_stop(owner)
    end)

    session = owner |> session_for() |> Map.merge(%{instance_mode: "hosted", port: port})
    assert :ok = AccountGeneration.seed_from_account_read(session, %{auth_mode: "apikey"})

    payload = %{"method" => "account/updated", "params" => %{"authMode" => "headers", "authorization" => "secret"}}

    assert {:error, {:turn_unretryable, {:unsafe_hosted_authentication, "codex", :headers}}} =
             Notifications.handle_account(session, base_state(), "account/updated", payload)

    assert_received {:event, :notification}
  end

  test "local Codex subscription observations remain accepted" do
    owner = start_owner(mint: sequence_mint())
    session = session_for(owner)

    on_exit(fn -> Aiur.TestSupport.safe_stop(owner) end)

    assert :ok = AccountGeneration.seed_from_account_read(session, %{auth_mode: "chatgpt"})
    assert %{generation: generation} = ProviderAccountGeneration.lookup(owner, :codex, :app_server, session.account_generation_binding)
    assert is_binary(generation)
  end
end
