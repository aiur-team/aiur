defmodule Aiur.Opencode.SessionGC do
  @moduledoc """
  Boot-time garbage collection of Aiur-owned opencode sessions whose
  identifier is no longer in `Aiur.Orchestrator.list_active_identifiers/0`.

  Recovery path for crash-out conditions (SIGKILL, OOM, BEAM panic)
  that bypass the three-layer shutdown defense. Run by the first
  ready slot once it has a `base_url` to talk to opencode.

  Lifted from the deleted `Aiur.Opencode.WarmServer.gc_leftover_sessions/1`.
  The slot model never creates `_warm` or `_placeholder` sessions, so
  the legacy "skip placeholder titles" exclusion is gone — any session
  with those titles is a crash leftover and SHOULD be deleted.
  """

  require Logger

  alias Aiur.Boot
  alias Aiur.Opencode.{ApiClient, Protocol}

  @doc """
  Run garbage collection against the opencode server at `base_url`.
  Deletes every Aiur-owned session (`model.providerID == "aiur"`) whose
  title is not in the current `list_active_identifiers/0` set.

  Returns `:ok` either way — failures are logged, not raised.
  """
  @spec run(String.t()) :: :ok
  def run(base_url) when is_binary(base_url) do
    active = MapSet.new(Aiur.Orchestrator.list_active_identifiers())

    case ApiClient.list_sessions(base_url) do
      {:ok, sessions} ->
        deleted =
          sessions
          |> Enum.filter(&aiur_orphan?(&1, active))
          |> Enum.map(fn session ->
            id = session["id"] || session[:id]
            _ = ApiClient.delete_session(base_url, id)
            id
          end)
          |> Enum.count()

        kept = length(sessions) - deleted

        Logger.info("opencode_session_gc phase=complete elapsed_ms=#{Boot.elapsed_ms()} kept=#{kept} deleted=#{deleted}")

      {:error, reason} ->
        Logger.warning("opencode_session_gc phase=skipped elapsed_ms=#{Boot.elapsed_ms()} reason=#{inspect(reason)}")
    end

    :ok
  end

  defp aiur_orphan?(session, active_set) do
    title = session["title"] || session[:title] || ""
    model = parse_model_field(session["model"] || session[:model])

    Protocol.aiur_owned?(model) and not MapSet.member?(active_set, title)
  end

  defp parse_model_field(model) when is_map(model), do: model

  defp parse_model_field(model) when is_binary(model) do
    case Jason.decode(model) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp parse_model_field(_), do: %{}
end
