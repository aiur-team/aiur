defmodule Aiur.Executor.SessionRecord do
  @moduledoc false
  require Logger
  alias Aiur.Config.Paths
  alias Aiur.Executor.StatePaths
  alias Aiur.JsonStore

  @fields ~w(v binding_id generation harness state provider_session_id transcript_path locator_hash cwd consumer_id attached_at last_hook_at takeover_armed detached_at end_reason transcript_offset pid start_reason transcript_format)a

  @spec path(String.t()) :: Path.t()
  def path(key) do
    # Encode unusual keys without path traversal or collisions.
    leaf = if Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, key), do: key, else: "~" <> Base.url_encode64(key, padding: false)
    Path.join(StatePaths.dir(), "#{Paths.repo_name()}.#{leaf}.executor.session.json")
  end

  @spec new(map(), map() | nil, DateTime.t()) :: map()
  def new(opts, previous, now) do
    %{
      v: 1,
      binding_id: "exb_" <> Base.encode32(:crypto.strong_rand_bytes(16), case: :lower, padding: false),
      generation: if(previous, do: previous.generation + 1, else: 1),
      harness: opts.harness,
      state: "awaiting_first_hook",
      provider_session_id: nil,
      transcript_path: nil,
      locator_hash: nil,
      cwd: nil,
      consumer_id: Map.get(opts, :consumer_id),
      attached_at: DateTime.to_iso8601(now),
      last_hook_at: nil,
      takeover_armed: Map.get(opts, :takeover?, false) == true,
      detached_at: nil,
      end_reason: nil,
      transcript_offset: 0,
      pid: nil,
      start_reason: "start"
    }
  end

  @spec load(Path.t()) :: map() | nil
  def load(path) do
    case JsonStore.read(path, :missing) do
      {:ok, :missing} -> nil
      {:ok, data} -> decode_or_quarantine(path, data)
      {:error, %Jason.DecodeError{}} -> quarantine(path)
      # An unreadable binding may still own a live Executor; fail closed instead of overwriting it.
      {:error, reason} -> raise File.Error, reason: reason, action: "read Executor binding", path: path
    end
  end

  defp decode_or_quarantine(path, data) do
    if valid?(data), do: Map.new(@fields, &{&1, Map.get(data, Atom.to_string(&1))}), else: quarantine(path)
  end

  defp valid?(%{"v" => 1, "binding_id" => id, "generation" => generation, "harness" => harness, "state" => state} = data) do
    valid_identity?(id, generation, harness, state) and valid_times?(data) and valid_fields?(data)
  end

  defp valid?(_data), do: false

  defp valid_identity?(id, generation, harness, state) do
    is_binary(id) and String.starts_with?(id, "exb_") and is_integer(generation) and generation > 0 and
      harness in ["claude", "codex"] and state in ["awaiting_first_hook", "attached", "detached"]
  end

  defp valid_times?(data), do: valid_time?(data["attached_at"]) and (is_nil(data["last_hook_at"]) or valid_time?(data["last_hook_at"]))

  defp valid_fields?(data) do
    is_integer(data["transcript_offset"]) and data["transcript_offset"] >= 0 and is_boolean(data["takeover_armed"]) and
      Enum.all?(~w(provider_session_id transcript_path locator_hash cwd consumer_id pid start_reason detached_at end_reason), &(is_nil(data[&1]) or is_binary(data[&1])))
  end

  defp valid_time?(value) when is_binary(value), do: match?({:ok, _, _}, DateTime.from_iso8601(value))
  defp valid_time?(_value), do: false

  defp quarantine(path) do
    File.rename!(path, path <> ".corrupt-#{System.system_time(:microsecond)}")
    Logger.warning("Executor binding corrupt; preserved quarantined record")
    nil
  end
end
