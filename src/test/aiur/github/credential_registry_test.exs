defmodule Aiur.GitHub.CredentialRegistryTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema.GithubCredential
  alias Aiur.GitHub.{Credential, CredentialRegistry}

  describe "single-credential back-compat" do
    test "the legacy credential is primary, write-eligible and delegates to Config.token/0" do
      legacy = CredentialRegistry.legacy_credential()

      assert legacy.primary?
      assert legacy.writes?
      assert legacy.source == :legacy
      assert legacy.id == "primary"
    end

    test "no configured credentials means exactly one entry and no pooling" do
      # `Aiur.Config` in test has no `credentials:` list, which is the shipped
      # default: the registry must be the single legacy credential.
      credentials = CredentialRegistry.configured()

      assert [%Credential{id: "primary", primary?: true}] = credentials
      refute CredentialRegistry.pooled?(credentials: credentials)
    end
  end

  describe "resolution" do
    test "a credential whose env var is not exported is dropped from the pool" do
      present = %Credential{id: "present", kind: :machine_user, token_env: "AIUR_TEST_PRESENT_TOKEN", primary?: true}
      absent = %Credential{id: "absent", kind: :machine_user, token_env: "AIUR_TEST_ABSENT_TOKEN"}

      System.put_env("AIUR_TEST_PRESENT_TOKEN", "present-token")
      on_exit(fn -> System.delete_env("AIUR_TEST_PRESENT_TOKEN") end)

      assert [%Credential{id: "present"}] = CredentialRegistry.credentials(credentials: [present, absent])
      assert [_present, _absent] = CredentialRegistry.configured(credentials: [present, absent])
    end

    test "by_token_key/2 and by_id/2 find a resolvable credential" do
      credential = %Credential{id: "found", kind: :machine_user, token_env: "AIUR_TEST_FOUND_TOKEN"}
      System.put_env("AIUR_TEST_FOUND_TOKEN", "found-token")
      on_exit(fn -> System.delete_env("AIUR_TEST_FOUND_TOKEN") end)

      key = Credential.token_key(credential)

      assert %Credential{id: "found"} = CredentialRegistry.by_token_key(key, credentials: [credential])
      assert %Credential{id: "found"} = CredentialRegistry.by_id("found", credentials: [credential])
      assert CredentialRegistry.by_token_key(nil, credentials: [credential]) == nil
    end
  end

  describe "config schema" do
    test "a human credential may not be configured for writes" do
      changeset = GithubCredential.changeset(%GithubCredential{}, %{"id" => "everdred", "kind" => "human", "token_env" => "T", "writes" => true})

      refute changeset.valid?
      assert {message, _meta} = changeset.errors[:writes]
      assert message =~ "human credential cannot be used for writes"
    end

    test "a human credential is valid read-only" do
      changeset = GithubCredential.changeset(%GithubCredential{}, %{"id" => "everdred", "kind" => "human", "token_env" => "EVERDRED_TOKEN"})

      assert changeset.valid?
    end

    test "a PAT credential must name a token env var" do
      changeset = GithubCredential.changeset(%GithubCredential{}, %{"id" => "applekid", "kind" => "machine_user"})

      refute changeset.valid?
      assert changeset.errors[:token_env]
    end

    test "an app installation credential needs no token env var" do
      changeset = GithubCredential.changeset(%GithubCredential{}, %{"id" => "app", "kind" => "app_installation", "writes" => true})

      assert changeset.valid?
    end

    test "an unknown kind is rejected" do
      changeset = GithubCredential.changeset(%GithubCredential{}, %{"id" => "x", "kind" => "service_account", "token_env" => "T"})

      refute changeset.valid?
      assert changeset.errors[:kind]
    end
  end
end
