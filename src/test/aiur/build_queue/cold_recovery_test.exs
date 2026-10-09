defmodule Aiur.BuildQueue.ColdRecoveryTest do
  use ExUnit.Case, async: false

  test "cold server loads producer atoms before decoding persisted latches" do
    key = {:promoted_unauthorized, "1"} |> :erlang.term_to_binary() |> Base.encode64()

    reason = :not_applied |> :erlang.term_to_binary() |> Base.encode64()

    script = """
    defmodule ColdBoundary do
      def open_issue_labels(_), do: :none
      def load do
        {:ok, _} = Aiur.BuildQueue.Model.decode(%{
          "version" => 1, "queues" => [], "items" => [], "edges" => [],
          "intents" => [%{"id" => "cold-intent", "issue_id" => "1", "action" => "promote", "target_labels" => [], "recorded_at_ms" => 1, "outcome" => %{"error" => "#{reason}"}}],
          "latches" => [%{"key" => "#{key}", "opened_at_ms" => 1, "emitted?" => false}]
        })
        {:error, :cold_probe_complete}
      end
    end
    {:ok, state} = Aiur.BuildQueue.Server.init(settings: {:ok, %{build_queue: %{enabled: true}}}, tracker: ColdBoundary, store: ColdBoundary)
    true = state.status == :store_unavailable
    IO.puts("cold recovery decoded")
    """

    # Coverage runs cover-compile modules in memory, so :code.which/1 has no path; the app ebin always does.
    ebin = Application.app_dir(:aiur, "ebin")
    {output, status} = System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "cold recovery decoded"
  end
end
