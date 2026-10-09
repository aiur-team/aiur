defmodule Aiur.BuildQueue.ColdRecoveryTest do
  use ExUnit.Case, async: false

  test "cold server loads producer atoms before decoding persisted latches" do
    key = {:promoted_unauthorized, "1"} |> :erlang.term_to_binary() |> Base.encode64()

    script = """
    defmodule ColdBoundary do
      def open_issue_labels(_), do: :none
      def load do
        {:ok, _} = Aiur.BuildQueue.Model.decode(%{
          "version" => 1, "queues" => [], "items" => [], "edges" => [], "intents" => [],
          "latches" => [%{"key" => "#{key}", "opened_at_ms" => 1, "emitted?" => false}]
        })
        {:error, :cold_probe_complete}
      end
    end
    {:ok, state} = Aiur.BuildQueue.Server.init(settings: {:ok, %{build_queue: %{enabled: true}}}, tracker: ColdBoundary, store: ColdBoundary)
    true = state.status == :store_unavailable
    IO.puts("cold recovery decoded")
    """

    ebin = :code.which(Aiur.BuildQueue.Server) |> List.to_string() |> Path.dirname()
    {output, status} = System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "cold recovery decoded"
  end
end
