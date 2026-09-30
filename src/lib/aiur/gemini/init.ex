defmodule Aiur.Gemini.Init do
  @moduledoc "Native Gemini CLI onboarding defaults."

  @spec prompt(term()) :: map()
  def prompt(_io), do: %{}

  @spec config(map()) :: map()
  def config(_answers), do: %{"command" => "gemini --acp"}
end
