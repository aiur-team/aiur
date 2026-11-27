defmodule AiurPushRelay.ApnsFake do
  @moduledoc false
  def start(responses), do: Agent.start_link(fn -> {responses, []} end)

  def transport(pid) do
    fn request ->
      Agent.get_and_update(pid, fn {[response | rest], requests} ->
        {response, {rest, requests ++ [request]}}
      end)
    end
  end

  def requests(pid), do: Agent.get(pid, fn {_, requests} -> requests end)

  def response(status, reason \\ ""),
    do: {:ok, %{status: status, body: Jason.encode!(%{reason: reason})}}
end
