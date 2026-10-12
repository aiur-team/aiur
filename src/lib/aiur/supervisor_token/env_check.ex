defmodule Aiur.SupervisorToken.EnvCheck do
  @moduledoc "Startup validation for the Supervisor Decision API credential."

  @behaviour Aiur.Env.StartupCheck

  @impl true
  def errors(env) do
    case Aiur.SupervisorToken.classify(Map.get(env, "AIUR_SUPERVISOR_TOKEN")) do
      :invalid -> ["AIUR_SUPERVISOR_TOKEN must be a bearer-safe token of at least 32 bytes with no surrounding whitespace"]
      _missing_or_valid -> []
    end
  end
end
