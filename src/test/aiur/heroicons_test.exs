defmodule Aiur.HeroiconsTest do
  use ExUnit.Case, async: true

  alias Aiur.Heroicons

  test "resolves every outline name and keeps legacy names visually aliased" do
    assert "book-open" in Heroicons.names()
    assert Heroicons.valid?("server")
    assert Heroicons.svg("server") == Heroicons.svg("server-stack")
    assert Heroicons.svg("unknown") == Heroicons.svg("squares-2x2")
  end
end
