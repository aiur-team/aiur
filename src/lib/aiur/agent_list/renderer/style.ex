defmodule Aiur.AgentList.Renderer.Style do
  @moduledoc """
  ANSI palette helpers for the agent-list renderer.
  """

  @spec reset() :: String.t()
  def reset, do: IO.ANSI.reset()

  @spec bold() :: String.t()
  def bold, do: IO.ANSI.bright()

  @spec dim() :: String.t()
  def dim, do: IO.ANSI.faint()

  @spec cyan() :: String.t()
  def cyan, do: IO.ANSI.cyan()

  @spec gray() :: String.t()
  def gray, do: IO.ANSI.light_black()

  @spec green() :: String.t()
  def green, do: IO.ANSI.green()

  @spec red() :: String.t()
  def red, do: IO.ANSI.red()

  @spec reverse() :: String.t()
  def reverse, do: IO.ANSI.reverse()

  @spec magenta() :: String.t()
  def magenta, do: IO.ANSI.magenta()

  @spec blue() :: String.t()
  def blue, do: IO.ANSI.blue()
end
