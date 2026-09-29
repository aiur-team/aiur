defmodule Aiur.Gemini.Init do
  @moduledoc "Native Gemini CLI onboarding defaults."

  def prompt(_io), do: %{}
  def config(_answers), do: %{"command" => "gemini --acp"}
end
