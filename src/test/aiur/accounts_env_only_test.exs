defmodule Aiur.AccountsEnvOnlyTest do
  use Aiur.TestSupport

  alias Aiur.Accounts
  alias Aiur.OpenAICompat.Config, as: OpenAIConfig

  setup do
    home = Aiur.TestSupport.tmp_root!("aiur-accounts-env-only")
    File.mkdir_p!(Path.join(home, ".aiur"))
    previous_home = System.get_env("HOME")
    previous_mode = System.get_env("AIUR_SECRETS_FROM_ENV")
    previous_key = System.get_env("DEEPSEEK_API_KEY")

    System.put_env("HOME", home)
    System.put_env("AIUR_SECRETS_FROM_ENV", "1")
    System.delete_env("DEEPSEEK_API_KEY")

    on_exit(fn ->
      restore_env("HOME", previous_home)
      restore_env("AIUR_SECRETS_FROM_ENV", previous_mode)
      restore_env("DEEPSEEK_API_KEY", previous_key)
      Aiur.TestCleanup.rm_rf!(home)
    end)

    %{home: home}
  end

  test "provider keys present only in the home dotenv file stay missing", %{home: home} do
    File.write!(Path.join(home, ".aiur/.env"), "DEEPSEEK_API_KEY__WORK=dotenv-only-secret\n")

    instance = %{
      base_url: "https://example.invalid/v1",
      api_key_env: "DEEPSEEK_API_KEY",
      default_model: "deepseek-v4-flash",
      transport: :responses,
      quirks: %{}
    }

    assert {:error, {:missing_api_key, "DEEPSEEK_API_KEY"}} =
             OpenAIConfig.resolve(
               backend: "deepseek",
               instance: instance,
               backend_config: %{},
               account_name: "work"
             )
  end

  test "account registration ignores keys found only in home dotenv", %{home: home} do
    File.write!(Path.join(home, ".aiur/.env"), "DEEPSEEK_API_KEY__WORK=dotenv-only-secret\n")

    assert {:error, {:missing_account_key, "DEEPSEEK_API_KEY__WORK"}} = Accounts.register("deepseek", "work", nil)
  end
end
