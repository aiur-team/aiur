defmodule Aiur.Opencode.WorkspaceSetup do
  @moduledoc false

  alias Aiur.Opencode.{Config, Protocol, TokenRegistry}

  @spec materialize(Path.t(), String.t(), String.t(), String.t(), non_neg_integer() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def materialize(workspace, identifier, bridge_url, token, opencode_os_pid \\ nil)
      when is_binary(workspace) and is_binary(identifier) and is_binary(bridge_url) and is_binary(token) do
    config =
      Protocol.opencode_json(%{
        bridge_url: bridge_url,
        bridge_token: token,
        identifier: identifier,
        model_prefix: Config.model_prefix(),
        opencode_os_pid: opencode_os_pid
      })

    tui = Protocol.tui_json()
    theme = Protocol.aiur_theme_json()

    with :ok <- File.mkdir_p(Path.join(workspace, ".opencode/themes")),
         :ok <- File.write(Path.join(workspace, "opencode.json"), Jason.encode!(config, pretty: true)),
         :ok <- File.write(Path.join(workspace, "tui.json"), Jason.encode!(tui, pretty: true)),
         :ok <- File.write(Path.join(workspace, ".opencode/themes/aiur.json"), Jason.encode!(theme, pretty: true)) do
      TokenRegistry.put(token, Config.safe_identifier(identifier))
      {:ok, token}
    end
  end
end
