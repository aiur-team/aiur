defmodule Aiur.AgentCompaction.CodexClient do
  @moduledoc "Provider-neutral access to the compaction capability declared by a backend."

  @spec request_compact(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def request_compact(session, thread_id, opts) do
    case session do
      %{backend: backend} -> Aiur.CodingAgent.adapter(backend).compact_session(session, thread_id, opts)
      _ -> {:error, :invalid_session}
    end
  end
end
