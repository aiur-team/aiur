defmodule Aiur.GitHub.Transport.TestScope do
  @moduledoc false

  alias Aiur.GitHub.QueueCost
  alias Aiur.GitHub.Transport.AuthDiagnostic

  @spec run(map(), (map() -> term())) :: term()
  def run(request, execute) when is_function(execute, 1) do
    Aiur.TestTicketScope.with_write_scope(request, fn ->
      case request do
        %{token: token} when is_binary(token) -> AuthDiagnostic.run(request, execute)
        request -> request |> QueueCost.tag() |> execute.()
      end
    end)
  end
end
