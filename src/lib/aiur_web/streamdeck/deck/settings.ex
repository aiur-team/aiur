defmodule AiurWeb.Streamdeck.Deck.Settings do
  @moduledoc "Per-instance deck preferences, committed atomically before they are applied."

  alias Aiur.Config.Paths
  alias AiurWeb.EndpointConfig

  @categories ~w(command ci_red error usage_limited)
  @defaults %{
    "mic_id" => nil,
    "speaker_id" => nil,
    "default_view" => "ticket",
    "default_sort" => "state",
    "brightness" => nil,
    "dim_after_seconds" => 0,
    "instance" => nil,
    "alerts" => Map.new(@categories, &{&1, %{"flash" => true, "chime" => &1 == "command"}})
  }

  @spec defaults() :: map()
  def defaults, do: @defaults

  @spec path() :: Path.t()
  def path do
    EndpointConfig.get(:streamdeck_settings_path) || Paths.streamdeck_settings_path(instance_key())
  end

  @spec read(Path.t()) :: {:ok, map()} | {:error, term()}
  def read(path \\ path()) do
    with {:ok, body} <- File.read(path),
         {:ok, value} <- Jason.decode(body),
         {:ok, settings} <- merge(@defaults, value) do
      {:ok, settings}
    else
      {:error, :enoent} -> {:ok, @defaults}
      error -> error
    end
  end

  @spec set(map(), Path.t()) :: {:ok, map()} | {:error, term()}
  def set(patch, path \\ path()) do
    :global.trans({{__MODULE__, path}, self()}, fn ->
      with {:ok, current} <- read(path),
           {:ok, candidate} <- merge(current, patch),
           :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- Aiur.Fs.atomic_write(path, Jason.encode!(candidate), mode: 0o600, fsync: true) do
        {:ok, candidate}
      end
    end)
  end

  @spec merge(map(), term()) :: {:ok, map()} | {:error, :invalid_settings}
  def merge(current, patch) when is_map(patch) do
    if map_size(patch) <= map_size(@defaults) and Enum.all?(patch, &valid?/1) do
      candidate = Map.merge(current, patch)
      candidate = if is_integer(candidate["brightness"]), do: Map.update!(candidate, "brightness", &min(max(&1, 0), 100)), else: candidate
      {:ok, candidate}
    else
      {:error, :invalid_settings}
    end
  end

  def merge(_current, _patch), do: {:error, :invalid_settings}

  defp valid?({key, value}) when key in ["mic_id", "speaker_id", "instance"], do: is_nil(value) or (is_binary(value) and byte_size(value) in 1..256)
  defp valid?({"default_view", value}), do: value in ~w(ticket feature epic fleet)
  defp valid?({"default_sort", value}), do: value in ~w(state priority title)
  defp valid?({"brightness", value}), do: is_nil(value) or is_integer(value)
  defp valid?({"dim_after_seconds", value}), do: is_integer(value) and value in 0..86_400

  defp valid?({"alerts", value}) when is_map(value) do
    Enum.sort(Map.keys(value)) == Enum.sort(@categories) and
      Enum.all?(value, fn {_key, flags} -> is_map(flags) and Enum.sort(Map.keys(flags)) == ~w(chime flash) and Enum.all?(Map.values(flags), &is_boolean/1) end)
  end

  defp valid?(_entry), do: false

  defp instance_key do
    case Aiur.Identity.instance_key() do
      {:ok, key} -> key
      {:error, :instance_key_missing} -> "default"
      {:error, :instance_key_invalid} -> raise ArgumentError, "invalid instance key for deck settings"
    end
  end

end
