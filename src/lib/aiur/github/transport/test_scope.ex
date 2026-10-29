defmodule Aiur.GitHub.Transport.TestScope do
  @moduledoc false

  alias Aiur.GitHub.Access.Settings
  alias Aiur.GitHub.Transport.AuthDiagnostic

  @spec run(map(), (map() -> term())) :: term()
  def run(request, execute) when is_function(execute, 1) do
    Settings.current().write_scope.(request, fn ->
      case request do
        %{token: token} when is_binary(token) ->
          AuthDiagnostic.run(request, execute)

        request ->
          request |> tag() |> execute.()
      end
    end)
  end

  @doc false
  @spec tag(map()) :: map()
  def tag(request), do: Enum.reduce(Settings.current().request_taggers, request, & &1.(&2))
end
