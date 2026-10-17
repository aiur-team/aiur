defmodule Aiur.CLI.Usage do
  @moduledoc false

  @spec message() :: String.t()
  def message do
    "Usage: aiur [--interactive] [--headless] [--executor] [--no-dashboard] [--pause] [--max-agents <n>] [--logs-root <path>] [--port <port>] [--host <host>] [config-path]\n       aiur init [--force]\n       aiur --todo <id> [<id> ...] [--only]\n       aiur findings [--unfiled] [--slugs] [--scope aiur|repo]\n       aiur findings --record <json> --repo <owner/repo>\n       aiur findings --digest [--scope aiur|repo]\n       aiur ask <title> [--body <text>|--body-file <path>] [--urgency low|normal|high] [--blocking]\n       aiur ask --done <id> [--note <text>]\n       aiur asks [--open|--all] [--json]"
  end
end
