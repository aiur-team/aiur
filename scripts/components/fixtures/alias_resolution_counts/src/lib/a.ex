defmodule A do
  alias B.{Internal}
  def f, do: Internal.f()
end
