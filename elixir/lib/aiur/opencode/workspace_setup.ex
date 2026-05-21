defmodule Aiur.Opencode.WorkspaceSetup do
  @moduledoc """
  Writes a slot's on-disk workspace files: `opencode.json` (provider +
  models + bridge token), `tui.json` (theme selector), and
  `.opencode/themes/aiur.json` (the aiur theme). Called by
  `Aiur.Opencode.Slot` on initial materialization and on every serve
  rebuild (incremental identifier_miss path).
  """

  alias Aiur.Opencode.{Config, Protocol, TokenRegistry}

  @doc """
  Materialize a per-slot workspace with `opencode.json` declaring the
  agent identifiers passed in `agent_identifiers`. The slot worker
  registers the returned token against `slot_index` + `generation` in
  `Aiur.Opencode.TokenRegistry` so the bridge can authorize chat
  completions originating from this slot's opencode-serve.

  When `agent_identifiers` is `[]`, the slot's `opencode.json` lists
  only the slot sentinel (`issue-_slot-N`) — no agent models. This is
  the on-demand case: the slot is ready to attach but no user has
  selected an agent for it yet. Subsequent `Slot.select/2` calls grow
  the models map incrementally via the rebuild path.
  """
  @spec materialize_slot(Path.t(), String.t(), [String.t()], pos_integer(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def materialize_slot(workspace, bridge_url, agent_identifiers, slot_index, generation)
      when is_binary(workspace) and is_binary(bridge_url) and is_list(agent_identifiers) and
             is_integer(slot_index) and is_integer(generation) do
    token = generate_token()

    config =
      Protocol.opencode_json(%{
        bridge_url: bridge_url,
        bridge_token: token,
        identifier: "_slot-#{slot_index}",
        model_prefix: Config.model_prefix(),
        opencode_os_pid: nil,
        extra_identifiers: agent_identifiers
      })

    tui = Protocol.tui_json()
    theme = Protocol.aiur_theme_json()

    with :ok <- File.mkdir_p(Path.join(workspace, ".opencode/themes")),
         :ok <-
           File.write(Path.join(workspace, "opencode.json"), Jason.encode!(config, pretty: true)),
         :ok <- File.write(Path.join(workspace, "tui.json"), Jason.encode!(tui, pretty: true)),
         :ok <-
           File.write(
             Path.join(workspace, ".opencode/themes/aiur.json"),
             Jason.encode!(theme, pretty: true)
           ) do
      TokenRegistry.put(token, slot_index, generation)
      {:ok, token}
    end
  end

  defp generate_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
