defmodule Aiur.Upgrade.State do
  @moduledoc """
  Durable upgrade-check state shared between the BEAM (which refreshes it from
  the registry) and the launcher/engine (which surfaces and acknowledges it).

  Two files under the Aiur state dir, so each side only ever writes what it
  owns and the engine needs no JSON rewriting:

    * `upgrade.json` — BEAM-owned: `last_check_ms` (the TTL gate that stops
      per-run phone-homes), `dist_tags`, and the pending `notice`. Writes are
      write-then-rename so a concurrent reader never sees a torn file.
    * `upgrade-notified.txt` — engine-owned: the version (or `gone:<channel>`
      sentinel) the operator was last told about. The BEAM reads it for the
      no-repeat decision but never writes it, so a refresh can never re-nag.
  """

  @type t :: %{
          optional(:last_check_ms) => non_neg_integer() | nil,
          optional(:dist_tags) => map(),
          optional(:notice) => map() | nil
        }

  @doc "The BEAM-owned state file path, under `AIUR_BG_STATE_DIR` (or the XDG config home)."
  @spec path() :: Path.t()
  def path do
    Path.join(state_dir(), "upgrade.json")
  end

  @doc "The engine-owned 'last told' marker path."
  @spec notified_path() :: Path.t()
  def notified_path do
    Path.join(state_dir(), "upgrade-notified.txt")
  end

  defp state_dir do
    case System.get_env("AIUR_BG_STATE_DIR") do
      value when is_binary(value) and value != "" -> value
      _ -> Path.join(Path.expand(System.get_env("XDG_CONFIG_HOME") || "~/.config"), "aiur")
    end
  end

  @doc "Read the state file. Returns `{:ok, map}` or `:error` (missing/corrupt)."
  @spec read(Path.t() | nil) :: {:ok, t()} | :error
  def read(file \\ nil) do
    case File.read(file || path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> {:ok, normalize(map)}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @doc "Atomically write the state file. Creates the parent directory as needed."
  @spec write(map(), Path.t() | nil) :: :ok | {:error, term()}
  def write(map, file \\ nil) do
    target = file || path()
    File.mkdir_p!(Path.dirname(target))
    tmp = "#{target}.tmp.#{:erlang.unique_integer([:positive])}"

    case File.write(tmp, Jason.encode!(map)) do
      :ok ->
        case File.rename(tmp, target) do
          :ok ->
            :ok

          {:error, _reason} = error ->
            File.rm(tmp)
            error
        end

      {:error, _reason} = error ->
        File.rm(tmp)
        error
    end
  end

  @doc "Empty state with a nil notice, used when no state file exists yet."
  @spec default() :: t()
  def default do
    %{last_check_ms: nil, dist_tags: %{}, notice: nil}
  end

  @doc "The last-announced version marker (or nil when the operator was never told)."
  @spec read_notified(Path.t() | nil) :: String.t() | nil
  def read_notified(file \\ nil) do
    case File.read(file || notified_path()) do
      {:ok, body} ->
        case String.trim(body) do
          "" -> nil
          value -> value
        end

      _ ->
        nil
    end
  end

  @doc "Atomically write the last-announced marker."
  @spec write_notified(String.t(), Path.t() | nil) :: :ok | {:error, term()}
  def write_notified(value, file \\ nil) do
    target = file || notified_path()
    File.mkdir_p!(Path.dirname(target))
    tmp = "#{target}.tmp.#{:erlang.unique_integer([:positive])}"

    case File.write(tmp, value <> "\n") do
      :ok ->
        case File.rename(tmp, target) do
          :ok ->
            :ok

          {:error, _reason} = error ->
            File.rm(tmp)
            error
        end

      {:error, _reason} = error ->
        File.rm(tmp)
        error
    end
  end

  defp normalize(map) do
    %{
      last_check_ms: Map.get(map, "last_check_ms") || Map.get(map, :last_check_ms),
      dist_tags: Map.get(map, "dist_tags") || Map.get(map, :dist_tags) || %{},
      notice: Map.get(map, "notice") || Map.get(map, :notice)
    }
  end
end
