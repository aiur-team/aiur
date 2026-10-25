defmodule Aiur.Config.SemanticCheck do
  @moduledoc "Owner-provided semantic validation registered in application configuration."

  @callback applies?(map()) :: boolean()
  @callback check(map()) :: :continue | :ok | {:error, term()}
end
