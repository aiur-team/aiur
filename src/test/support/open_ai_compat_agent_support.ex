defmodule Aiur.TestSupport.OpenAICompatAgent do
  @moduledoc false
  # Shared workspace setup and request doubles for the OpenAI-compatible coding-agent suites.

  import ExUnit.Assertions

  alias Aiur.Issue

  defmacro __using__(_opts) do
    quote do
      import Aiur.TestSupport.OpenAICompatAgent

      setup do
        workspace =
          Path.join(
            Aiur.Config.workspace_root(),
            "aiur-openai-compat-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workspace)
        File.write!(Path.join(workspace, "sample.txt"), "workspace evidence\n")
        on_exit(fn -> File.rm_rf!(workspace) end)
        %{workspace: workspace}
      end
    end
  end

  def instance(extra) do
    %{
      base_url: "https://example.invalid/v1",
      api_key_env: "TEST_KEY",
      default_model: "deepseek-v4-flash",
      transport: :chat_completions,
      quirks: Map.new(extra)
    }
  end

  def response(body), do: {:ok, %{status: 200, body: body, headers: %{}}}

  def queue_fun(queue, parent) do
    fn request ->
      send(parent, {:request, request})

      Agent.get_and_update(queue, fn
        [next | rest] -> {next, rest}
        [] -> {{:error, :unexpected_request}, []}
      end)
    end
  end

  def collect_requests(count) do
    Enum.reduce(1..count, [], fn _, acc ->
      receive do
        {:request, request} -> [request | acc]
      after
        1_000 -> flunk("expected #{count} requests, received #{length(acc)}")
      end
    end)
    |> Enum.reverse()
  end

  def issue, do: %Issue{id: "1440", identifier: "1440", title: "compat test", labels: []}
end
