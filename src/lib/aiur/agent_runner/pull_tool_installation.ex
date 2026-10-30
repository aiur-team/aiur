defmodule Aiur.AgentRunner.PullToolInstallation do
  @moduledoc "Tracks whether this session actually registered the consuming read tool."
  alias Aiur.Harness.Capabilities
  alias Aiur.SessionHandle

  @spec stamp(map(), String.t(), keyword()) :: map()
  def stamp(session, identifier, opts \\ []) do
    Map.put(session, :pull_tool_installed, installed?(session, identifier, opts))
  end

  # Codex resumes keep the original dynamic tool catalog; resume cannot replace it.
  defp installed?(%{backend: "codex", resumed: true, thread_id: thread}, identifier, opts) do
    case SessionHandle.load(identifier, "codex", opts) do
      {:ok, %{thread_id: ^thread, pull_tool_installed: true}} -> true
      _ -> false
    end
  end

  defp installed?(%{backend: "codex", resumed: false}, _identifier, _opts), do: true
  defp installed?(%{backend: "codex"}, _identifier, _opts), do: false

  defp installed?(%{backend: backend}, _identifier, _opts) do
    case Capabilities.delivery_primitives(backend) do
      {:ok, %{pull_tool: true}} -> true
      _ -> false
    end
  end

  defp installed?(_session, _identifier, _opts), do: false
end
