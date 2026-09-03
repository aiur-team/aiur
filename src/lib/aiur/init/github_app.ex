defmodule Aiur.Init.GitHubApp do
  @moduledoc "GitHub App opt-in prompt for fresh `aiur init` setup."

  @github_token_choice "No — use my GITHUB_TOKEN"
  @github_app_choice "Yes — I'll set up a GitHub App"
  @prompt "Use a GitHub App for the daemon? (recommended if agents are hitting rate limits)"
  @setup_doc "docs/security/daemon-token-posture.md"

  @doc "Asks which daemon credential path a fresh GitHub setup will use."
  @spec prompt(Aiur.Init.io(), map()) :: :github_token | :github_app
  def prompt(io, %{kind: "github"}) do
    io.puts.(
      "\nOptional GitHub App upgrade:\n" <>
        "  • Higher rate limits for busy fleets.\n" <>
        "  • Tighter daemon permissions than a classic PAT."
    )

    case io.select.(@prompt, [@github_token_choice, @github_app_choice], @github_token_choice) do
      @github_app_choice ->
        io.puts.("GitHub App setup steps: #{@setup_doc}")
        :github_app

      _choice ->
        :github_token
    end
  end

  def prompt(_io, _tracker), do: :github_token
end
