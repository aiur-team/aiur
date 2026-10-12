defmodule Aiur.EngineSource do
  @moduledoc false
  @libexec Path.expand("../../../packaging/npm/aiur-cli/libexec", __DIR__)

  @doc "The launcher engine and every `engine/*.sh` module it sources, as one text."
  def text do
    [Path.join(@libexec, "aiur-engine.sh") | Enum.sort(Path.wildcard(Path.join(@libexec, "engine/*.sh")))]
    |> Enum.map_join("\n", &File.read!/1)
  end
end
