defmodule Aiur.GitHub.AppCredentialsTest do
  # async: false — these tests mutate the GITHUB_APP_* env vars.
  use ExUnit.Case, async: false

  alias Aiur.GitHub.AppCredentials

  @env_keys [
    "GITHUB_APP_ID",
    "GITHUB_APP_INSTALLATION_ID",
    "GITHUB_APP_PRIVATE_KEY",
    "GITHUB_APP_PRIVATE_KEY_PATH"
  ]

  # A real RSA private-key PEM (PKCS#8) so parse_private_key exercises the full
  # :public_key decode + JOSE.JWK path, not just "file read".
  defp real_pem do
    {_jwk, pem} = JOSE.JWK.to_pem(JOSE.JWK.generate_key({:rsa, 2048}))
    pem
  end

  setup do
    previous =
      Map.new(@env_keys, fn key -> {key, System.get_env(key)} end)

    Enum.each(@env_keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(@env_keys, fn key ->
        case Map.fetch!(previous, key) do
          nil -> System.delete_env(key)
          value -> System.put_env(key, value)
        end
      end)
    end)

    :ok
  end

  test "configured?/0 is false when any credential is missing" do
    System.put_env("GITHUB_APP_ID", "12345")
    System.put_env("GITHUB_APP_INSTALLATION_ID", "678")

    refute AppCredentials.configured?()

    System.put_env("GITHUB_APP_PRIVATE_KEY", real_pem())
    assert AppCredentials.configured?()
  end

  test "configured?/0 ignores blank values" do
    System.put_env("GITHUB_APP_ID", "   ")
    System.put_env("GITHUB_APP_INSTALLATION_ID", "678")
    System.put_env("GITHUB_APP_PRIVATE_KEY", real_pem())

    refute AppCredentials.configured?()
  end

  test "app_id/0 and installation_id/0 trim surrounding whitespace" do
    System.put_env("GITHUB_APP_ID", " 12345 ")
    System.put_env("GITHUB_APP_INSTALLATION_ID", " 678\n")

    assert AppCredentials.app_id() == "12345"
    assert AppCredentials.installation_id() == "678"
  end

  test "private_key_pem/0 reads the inline GITHUB_APP_PRIVATE_KEY" do
    pem = real_pem()
    System.put_env("GITHUB_APP_PRIVATE_KEY", pem)

    assert {:ok, resolved} = AppCredentials.private_key_pem()
    assert resolved == String.trim(pem)
  end

  test "private_key_pem/0 prefers GITHUB_APP_PRIVATE_KEY_PATH over the inline value" do
    path = Path.join(System.tmp_dir!(), "aiur-app-key-#{System.unique_integer([:positive])}.pem")
    pem = real_pem()
    File.write!(path, pem)

    on_exit(fn -> File.rm(path) end)

    System.put_env("GITHUB_APP_PRIVATE_KEY", "inline-should-lose")
    System.put_env("GITHUB_APP_PRIVATE_KEY_PATH", path)

    assert {:ok, resolved} = AppCredentials.private_key_pem()
    assert resolved == String.trim(pem)
  end

  test "private_key_pem/0 reports an unreadable path without leaking contents" do
    System.put_env("GITHUB_APP_PRIVATE_KEY_PATH", "/nonexistent/aiur/app-key.pem")

    assert {:error, {:private_key_path_unreadable, _path, _reason}} = AppCredentials.private_key_pem()
  end

  test "private_key_pem/0 returns :missing_private_key when nothing is configured" do
    assert {:error, :missing_private_key} = AppCredentials.private_key_pem()
  end

  test "parse_private_key/0 returns a JWK for a valid PEM" do
    System.put_env("GITHUB_APP_PRIVATE_KEY", real_pem())

    assert {:ok, jwk} = AppCredentials.parse_private_key()
    assert %JOSE.JWK{} = jwk
  end

  test "parse_private_key/0 rejects malformed PEM" do
    System.put_env("GITHUB_APP_PRIVATE_KEY", "definitely-not-a-key")

    assert {:error, :invalid_private_key} = AppCredentials.parse_private_key()
  end

  test "missing_credential/0 identifies the absent credential" do
    assert AppCredentials.missing_credential() == :missing_app_id

    System.put_env("GITHUB_APP_ID", "12345")
    assert AppCredentials.missing_credential() == :missing_installation_id

    System.put_env("GITHUB_APP_INSTALLATION_ID", "678")
    assert AppCredentials.missing_credential() == :missing_private_key
  end
end
