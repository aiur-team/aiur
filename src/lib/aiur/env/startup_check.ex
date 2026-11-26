defmodule Aiur.Env.StartupCheck do
  @moduledoc "Component-owned environment validation run after schema checks."

  @callback errors(env :: map()) :: [String.t()]
end
