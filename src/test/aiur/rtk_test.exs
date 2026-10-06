defmodule Aiur.RtkTest do
  use ExUnit.Case, async: true

  alias Aiur.Rtk

  @rtk "/usr/bin/rtk"

  # Stands in for the rtk executable. `responses` maps an argv list to the
  # `{output, exit_status}` pair rtk would produce, so a test states the CLI
  # behaviour it is modelling rather than a boolean.
  defp runner(responses) do
    fn _rtk, args -> Map.fetch!(responses, args) end
  end

  defp version_ok, do: %{["--version"] => {"rtk 0.47.0\n", 0}}

  # Verbatim shapes from rtk 0.47.0 on the host this was developed against.
  defp gh_rewritten, do: {"rtk gh pr view 1\n", 0}
  defp gh_excluded, do: {"No rewrite for: gh pr view 1\n", 1}

  defp gain(summary), do: {Jason.encode!(%{"summary" => summary}), 0}

  defp opts(responses, extra \\ []) do
    Keyword.merge([enabled?: true, rtk_path: @rtk, runner: runner(responses)], extra)
  end

  describe "status/1 admission" do
    test "is disabled when the operator has not enabled rtk" do
      assert Rtk.status(enabled?: false) == :disabled
    end

    test "reports rtk missing rather than refusing it" do
      assert Rtk.status(enabled?: true, rtk_path: nil) == {:unavailable, :not_installed}
    end

    test "admits rtk when its hook leaves gh alone" do
      responses = Map.merge(version_ok(), %{["hook", "check", "gh pr view 1"] => gh_excluded()})

      assert Rtk.status(opts(responses)) == {:ok, "0.47.0"}
    end

    # The load-bearing one. `gh` inside an agent workspace is the quota guard
    # wrapper, so an rtk hook that rewrites `gh` is rewriting the governed
    # path. Admitting rtk here would put an unaudited transform in front of
    # budget accounting and comment-marker stamping.
    test "refuses rtk when its hook would rewrite gh" do
      responses = Map.merge(version_ok(), %{["hook", "check", "gh pr view 1"] => gh_rewritten()})

      assert Rtk.status(opts(responses)) == {:refused, :gh_rewrite_not_excluded}
    end

    test "treats unrecognized probe output as unknown rather than as an exclusion" do
      responses =
        Map.merge(version_ok(), %{["hook", "check", "gh pr view 1"] => {"garbled\n", 1}})

      assert Rtk.status(opts(responses)) == {:unavailable, :probe_failed}
    end
  end

  describe "savings/1" do
    defp admitted(gain_response) do
      Map.merge(version_ok(), %{
        ["hook", "check", "gh pr view 1"] => gh_excluded(),
        ["gain", "-f", "json"] => gain_response
      })
    end

    test "reports the recorded saving" do
      summary = %{
        "total_commands" => 2,
        "total_input" => 469,
        "total_output" => 106,
        "total_saved" => 363,
        "avg_savings_pct" => 77.39872068230277
      }

      assert Rtk.savings(opts(admitted(gain(summary)))) ==
               {:ok,
                %{
                  commands: 2,
                  input_tokens: 469,
                  output_tokens: 106,
                  saved_tokens: 363,
                  savings_pct: 77.4
                }}
    end

    # rtk answers an empty history with `total_commands: 0` beside
    # `avg_savings_pct: 0.0`. Passing that through would render "0%", which
    # states rtk filtered output and saved nothing on it. It filtered nothing.
    test "separates an empty history from a measured zero" do
      empty = %{
        "total_commands" => 0,
        "total_input" => 0,
        "total_output" => 0,
        "total_saved" => 0,
        "avg_savings_pct" => 0.0
      }

      assert Rtk.savings(opts(admitted(gain(empty)))) == {:error, :no_data}
    end

    # A genuine zero is a different fact from an absent one and survives.
    test "reports a measured zero saving when commands were actually filtered" do
      measured_zero = %{
        "total_commands" => 5,
        "total_input" => 6,
        "total_output" => 6,
        "total_saved" => 0,
        "avg_savings_pct" => 0.0
      }

      assert {:ok, %{commands: 5, saved_tokens: 0, savings_pct: pct}} =
               Rtk.savings(opts(admitted(gain(measured_zero))))

      assert pct == 0.0
    end

    test "carries the refusal reason through instead of reporting no data" do
      responses = Map.merge(version_ok(), %{["hook", "check", "gh pr view 1"] => gh_rewritten()})

      assert Rtk.savings(opts(responses)) == {:error, :gh_rewrite_not_excluded}
    end

    test "reports unparsable output rather than a zero saving" do
      assert Rtk.savings(opts(admitted({"not json", 0}))) == {:error, :unparsable}
    end

    test "reports an unexpected payload rather than inventing a figure" do
      assert Rtk.savings(opts(admitted({Jason.encode!(%{"summary" => %{}}), 0}))) ==
               {:error, :unexpected_payload}
    end
  end

  describe "enabled?/1" do
    test "is off by default" do
      # Asserted on the schema field as well as through the reader: the reader
      # also answers `false` for a config it cannot destructure, so on its own
      # it would pass even if the shipped default were flipped to `true`.
      assert %Aiur.Config.Schema.Rtk{}.enabled == false
      refute Rtk.enabled?({:ok, %Aiur.Config.Schema{}})
    end

    test "is on when the operator set the flag" do
      settings = %Aiur.Config.Schema{agent: %Aiur.Config.Schema.Agent{rtk: %Aiur.Config.Schema.Rtk{enabled: true}}}

      assert Rtk.enabled?({:ok, settings})
    end

    # A config that cannot be read must not switch on a command rewriter.
    test "fails closed when the config cannot be read" do
      refute Rtk.enabled?({:error, :broken})
    end
  end
end
