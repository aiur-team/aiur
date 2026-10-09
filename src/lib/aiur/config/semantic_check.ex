defmodule Aiur.Config.SemanticCheck do
  @moduledoc "Owner-provided semantic validation registered in application configuration."

  @callback applies?(map()) :: boolean()
  @callback check(map()) :: :ok | {:error, term()}
end
