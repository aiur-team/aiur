defmodule Aiur.Accounts.EnvKey do
  @moduledoc false

  alias Aiur.Init.Dotenv

  @spec read(String.t()) :: String.t() | nil
  def read(name) do
    if Aiur.Secrets.secrets_from_env?() do
      System.get_env(name)
    else
      path = Path.join(System.get_env("HOME") || Path.expand("~"), ".aiur/.env")

      case File.read(path) do
        {:ok, contents} -> find_env_value(Dotenv.parse(contents), name)
        _ -> nil
      end
    end
  end

  defp find_env_value(entries, name), do: Enum.find_value(entries, fn {key, value} -> if key == name, do: nonempty(value), else: nil end)
  defp nonempty(""), do: nil
  defp nonempty(value), do: value
end
