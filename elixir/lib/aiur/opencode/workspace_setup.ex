defmodule Aiur.Opencode.WorkspaceSetup do
  @moduledoc false

  alias Aiur.Opencode.{Config, Protocol, TokenRegistry}

  @prewarm_identifier "_warm"

  @spec materialize(Path.t(), String.t(), String.t(), String.t(), non_neg_integer() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def materialize(workspace, identifier, bridge_url, token, opencode_os_pid \\ nil)
      when is_binary(workspace) and is_binary(identifier) and is_binary(bridge_url) and is_binary(token) do
    do_materialize(workspace, identifier, bridge_url, token, opencode_os_pid)
  end

  @doc """
  Materialize an `opencode.json` + `tui.json` + theme JSON inside a
  neutral pre-warm workspace (not a per-issue workspace). Used by
  `Aiur.Opencode.WarmServer` at aiur boot. The bridge token is
  registered against the literal `"_warm"` identifier so a stray
  `/v1/chat/completions` call against the placeholder session has a
  valid token to authenticate with — the bridge then refuses by
  matching `"placeholder"` (see `ChatCompletions.identifier_from_model/1`).
  """
  @spec materialize_prewarm(Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def materialize_prewarm(workspace, bridge_url)
      when is_binary(workspace) and is_binary(bridge_url) do
    token = generate_token()
    do_materialize(workspace, @prewarm_identifier, bridge_url, token, nil, [])
  end

  @doc """
  Rewrite the warm workspace's opencode.json so it declares every
  identifier in `agent_identifiers` as a valid model. Without this,
  opencode's TUI shows `Model not found: aiur/issue-<id>. Did you mean:
  issue-_warm?` in the chat pane — both broken UX and a `_warm` leak
  (R6 violation). Called by `Aiur.Opencode.AttachQueue` whenever it
  enqueues a new identifier.
  """
  @spec rematerialize_prewarm(Path.t(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  def rematerialize_prewarm(workspace, bridge_url, agent_identifiers)
      when is_binary(workspace) and is_binary(bridge_url) and is_list(agent_identifiers) do
    token = generate_token()

    do_materialize(
      workspace,
      @prewarm_identifier,
      bridge_url,
      token,
      nil,
      agent_identifiers
    )
  end

  defp do_materialize(workspace, identifier, bridge_url, token, opencode_os_pid, extra_identifiers \\ []) do
    config =
      Protocol.opencode_json(%{
        bridge_url: bridge_url,
        bridge_token: token,
        identifier: identifier,
        model_prefix: Config.model_prefix(),
        opencode_os_pid: opencode_os_pid,
        extra_identifiers: extra_identifiers
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

  defp generate_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
