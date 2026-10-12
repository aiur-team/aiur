defmodule Aiur.Opencode.AttachPool.PaintTest do
  # Characterization tests for code moved out of AttachPool unchanged: they
  # guard future regressions and pin the paint marker and geometry commands.
  # Paint talks to the registered `Aiur.Tmux`, so this cannot be async.
  use ExUnit.Case, async: false

  alias Aiur.Opencode.AttachPool.Paint
  alias Aiur.Tmux

  setup do
    {:ok, tmux} = start_supervised({Tmux, [transport: {:mock, self()}, name: Tmux, session: "test"]})
    %{tmux: tmux}
  end

  defp reply(tmux, lines), do: send(tmux, {:tmux_mock_data, Enum.join(["%begin 1 1 0"] ++ lines ++ ["%end 1 1 0"], "\n")})

  test "wait_for_paint returns :ok once the pane shows the message-turn marker", %{tmux: tmux} do
    task = Task.async(fn -> Paint.wait_for_paint("%7", 5_000) end)

    assert_receive {:tmux_mock_out, "capture-pane -p -t %7"}, 1_000
    reply(tmux, ["OPENCODE", "Ask anything..."])
    assert_receive {:tmux_mock_out, "capture-pane -p -t %7"}, 1_000
    reply(tmux, ["Build · issue-12"])

    assert Task.await(task) == :ok
  end

  test "wait_for_paint times out when the marker never appears", %{tmux: tmux} do
    task = Task.async(fn -> Paint.wait_for_paint("%7", 0) end)

    assert_receive {:tmux_mock_out, "capture-pane -p -t %7"}, 1_000
    reply(tmux, ["OPENCODE"])

    assert Task.await(task) == :timeout
  end

  test "ensure_hidden_geometry widens the hidden window to half the terminal per slot", %{tmux: tmux} do
    task = Task.async(fn -> Paint.ensure_hidden_geometry() end)

    assert_receive {:tmux_mock_out, "display-message -p -t aiur-orangekid-default:0" <> _}, 1_000
    reply(tmux, ["200 50"])
    assert_receive {:tmux_mock_out, "resize-window -t aiur-orangekid-default:aiur-hidden -x " <> size}, 1_000
    reply(tmux, [])
    assert_receive {:tmux_mock_out, "select-layout -t aiur-orangekid-default:aiur-hidden even-horizontal"}, 1_000
    reply(tmux, [])

    assert Task.await(task) == :ok
    assert [width, "-y", "50"] = String.split(size)
    assert rem(String.to_integer(width), 100) == 0
  end
end
