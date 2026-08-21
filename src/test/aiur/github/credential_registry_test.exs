defmodule Aiur.GitHub.CredentialRegistryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.Config.Schema.GithubCredential
  alias Aiur.GitHub.{Credential, CredentialRegistry}

  # Unique per credential. These tests are async and the process environment is
  # global, so a fixed name is shared with every other test wanting a credential
  # and one test's cleanup can unset another's token mid-run. An unresolvable
  # token collapses `token_key/1` to nil, which silently makes two credentials
  # look like one.
  defp credential(id, attrs) do
    env = "AIUR_TEST_TOKEN_#{String.upcase(id)}_#{System.unique_integer([:positive])}"

    struct!(%Credential{id: id, kind: :machine_user, identity: id, token_env: env}, attrs)
  end

  defp export(credential, token) do
    System.put_env(credential.token_env, token)
    on_exit(fn -> System.delete_env(credential.token_env) end)
    credential
  end

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
      present = export(credential("present", primary?: true), "present-token")
      absent = credential("absent", [])

      assert [%Credential{id: "present"}] = CredentialRegistry.credentials(credentials: [present, absent])
      assert [_present, _absent] = CredentialRegistry.configured(credentials: [present, absent])
    end

    # A host with no GitHub token configured is the ordinary unconfigured state,
    # and `Aiur.GitHub.Config.validate!/0` already reports it precisely. Pooling
    # must not add a second, vaguer line to that host's log.
    test "an absent legacy token logs nothing, while an absent pooled token warns" do
      legacy = %Credential{id: "primary", kind: :machine_user, source: :legacy, token_env: "AIUR_TEST_NEVER_SET", primary?: true}

      legacy_log = capture_log(fn -> assert CredentialRegistry.credentials(credentials: [legacy]) == [] end)

      assert legacy_log == "" or not (legacy_log =~ "github_credential_unavailable")

      pooled = credential("pooled_warn", [])
      :persistent_term.erase({CredentialRegistry, :warned, pooled.id})

      pooled_log = capture_log(fn -> assert CredentialRegistry.credentials(credentials: [pooled]) == [] end)

      assert pooled_log =~ "github_credential_unavailable"
      assert pooled_log =~ "id=pooled_warn"
    end

    test "by_token_key/2 and by_id/2 find a resolvable credential" do
      found = export(credential("found", []), "found-token")
      key = Credential.token_key(found)

      assert %Credential{id: "found"} = CredentialRegistry.by_token_key(key, credentials: [found])
      assert %Credential{id: "found"} = CredentialRegistry.by_id("found", credentials: [found])
      assert CredentialRegistry.by_token_key(nil, credentials: [found]) == nil
    end
  end

  describe "an unreadable config cannot take a request down" do
    # `Aiur.Config.settings/0` reaches a GenServer and throws an **exit** on
    # timeout; `Aiur.GitHub.Config.bot_account/0` goes through `settings!/0`
    # and **raises**. The registry sits on every GitHub request via `pooled?/1`,
    # so it has to survive both. A guard catching one and not the other reads as
    # safe and is not, which is exactly how this was first written.
    test "the settings read exiting degrades to the legacy credential alone" do
      credentials = CredentialRegistry.configured(settings_fun: fn -> exit(:timeout) end)

      assert [%Credential{id: "primary", primary?: true}] = credentials
      refute CredentialRegistry.pooled?(credentials: credentials)
    end

    test "the settings read raising degrades to the legacy credential alone" do
      credentials = CredentialRegistry.configured(settings_fun: fn -> raise ArgumentError, "no config" end)

      assert [%Credential{id: "primary", primary?: true}] = credentials
    end

    test "the identity read exiting still yields a usable legacy credential" do
      credential = CredentialRegistry.legacy_credential(identity_fun: fn -> exit(:timeout) end)

      assert %Credential{id: "primary", primary?: true, writes?: true, identity: nil} = credential
    end

    test "the identity read raising still yields a usable legacy credential" do
      credential = CredentialRegistry.legacy_credential(identity_fun: fn -> raise ArgumentError, "no config" end)

      assert %Credential{id: "primary", identity: nil} = credential
    end

    test "a healthy identity read is still used" do
      credential = CredentialRegistry.legacy_credential(identity_fun: fn -> "my-bot[bot]" end)

      assert credential.identity == "my-bot[bot]"
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
