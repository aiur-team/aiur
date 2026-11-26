defmodule Aiur.Secrets do
  @moduledoc false

  require Logger

  @truthy_values ["1", "true", "TRUE", "yes", "YES"]

  @spec secrets_from_env?() :: boolean()
  def secrets_from_env?, do: secrets_from_env?(System.get_env())

  @spec secrets_from_env?(map()) :: boolean()
  def secrets_from_env?(env), do: truthy?(env["AIUR_SECRETS_FROM_ENV"])

  @spec truthy?(term()) :: boolean()
  def truthy?(value), do: value in @truthy_values

  @spec warn_precedence_conflicts() :: :ok
  def warn_precedence_conflicts do
    warn_precedence_conflicts(
      System.get_env(),
      Path.join(System.user_home!(), ".aiur/.env"),
      Path.join(File.cwd!(), ".env")
    )
  end

  @spec warn_precedence_conflicts(map(), Path.t(), Path.t()) :: :ok
  def warn_precedence_conflicts(env, home, repo) do
    unless secrets_from_env?(env) do
      conflicts = Aiur.Env.precedence_conflicts(home, repo)
      Enum.each(Aiur.Env.precedence_warnings(conflicts), &Logger.warning/1)
    end

    :ok
  end
end
