defmodule Aiur.AgentLog.PageReaderTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentLog.PageReader

  setup do
    path = Path.join(System.tmp_dir!(), "page-reader-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    %{path: path}
  end

  test "pages preserve exact entries across chunks without gaps", %{path: path} do
    bodies = Enum.map(1..1_000, &"message #{&1} #{String.duplicate("x", 90)}")
    File.write!(path, Enum.map(bodies, &line/1))
    assert {:ok, tail} = PageReader.tail(path, limit: 17)
    entries = path |> older(tail, [tail]) |> Enum.flat_map(& &1.entries)
    assert Enum.map(entries, & &1.body) == bodies
    assert entries |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1_000
  end

  test "merge groups cross page edges and completions replace deltas", %{path: path} do
    File.write!(path, [line("first"), Enum.map(1..300, fn _ -> delta("x") end), completed("final"), line("last")])
    assert {:ok, page} = PageReader.tail(path, limit: 2)
    assert Enum.map(page.entries, & &1.body) == ["final", "last"]
    assert page.more?
    assert {:ok, earlier} = PageReader.before(path, page.first)
    assert Enum.map(earlier.entries, & &1.body) == ["first"]
  end

  test "completion barriers survive later deltas in backward and forward reads", %{path: path} do
    File.write!(path, [line(String.duplicate("prefix", 60)), delta("draft"), completed("final"), delta("!")])
    assert {:ok, page} = PageReader.tail(path)
    assert List.last(page.entries).body == "final!"
    assert page.last == List.last(page.entries).id
    assert {:ok, next} = PageReader.since(path, page.last)
    assert [%{body: "final!"}] = next.entries
    assert {:error, :invalid_cursor} = PageReader.since(path, page.last <> "\n")
  end

  test "since resends the final open group under its first id", %{path: path} do
    File.write!(path, [line(String.duplicate("prefix", 60)), delta("Hel"), delta("")])
    assert {:ok, page} = PageReader.tail(path)
    File.write!(path, delta("lo"), [:append])
    assert {:ok, next} = PageReader.since(path, page.last)
    assert [%{id: id, body: "Hello"}] = next.entries
    assert id == List.last(page.entries).id
    assert next.last == id
  end

  test "malformed and partial lines wait for completion", %{path: path} do
    File.write!(path, [line(String.duplicate("prefix", 60)), "bad json\n", String.trim_trailing(line("later"), "\n")])
    assert {:ok, page} = PageReader.tail(path)
    assert length(page.entries) == 1
    File.write!(path, "\n", [:append])
    assert {:ok, next} = PageReader.since(path, page.last)
    assert [%{body: "later"}] = next.entries
  end

  test "validates syntax, generation, size and line boundaries", %{path: path} do
    File.write!(path, [line("one"), line("two")])
    assert {:ok, page} = PageReader.tail(path)
    assert {:error, :invalid_cursor} = PageReader.before(path, "bad")
    assert {:error, :invalid_cursor} = PageReader.before(path, "#{page.gen}:1")
    assert {:error, :reset} = PageReader.before(path, "#{page.gen}:999999")
    File.write!(path, [line("new"), line("two")])
    assert {:error, :reset} = PageReader.since(path, page.last)
    assert {:ok, rewritten} = PageReader.tail(path)
    File.rename!(path, path <> ".old")
    File.write!(path, [line("new"), line("two")])
    assert {:error, :reset} = PageReader.since(path, page.last)
    assert {:error, :reset} = PageReader.since(path, rewritten.last)
    Aiur.TestCleanup.rm_rf!(path <> ".old")
  end

  test "truncation resets even when the fingerprint prefix is unchanged", %{path: path} do
    prefix = line(String.duplicate("prefix", 60))
    File.write!(path, [prefix, line("second")])
    assert {:ok, page} = PageReader.tail(path)
    File.write!(path, prefix)
    assert {:error, :reset} = PageReader.since(path, page.last)
  end

  test "empty files have no placeholder", %{path: path} do
    File.write!(path, "")
    assert {:ok, %{entries: [], more?: false}} = PageReader.tail(path)
  end

  test "huge lines are dropped and reads stay chunk bounded", %{path: path} do
    File.write!(path, [line("first"), String.duplicate("x", 5 * 1_048_576), "\n", line("last")])
    owner = self()

    pread = fn fd, offset, length ->
      send(owner, {:read_length, length})
      :file.pread(fd, offset, length)
    end

    assert {:ok, page} = PageReader.tail(path, pread: pread)
    assert Enum.map(page.entries, & &1.body) == ["Entry too large to show", "last"]
    assert page.more?
    assert {:ok, earlier} = PageReader.before(path, page.first)
    assert [%{body: "first"}] = earlier.entries
    lengths = read_lengths([])
    assert lengths != []
    assert Enum.all?(lengths, &(&1 <= 65_536))
  end

  test "tail stops at the byte budget and forward calls continue without gaps", %{path: path} do
    bodies = Enum.map(1..260, &"#{&1}:#{String.duplicate("x", 9_000)}")
    File.write!(path, Enum.map(bodies, &line/1))
    owner = self()

    pread = fn fd, offset, length ->
      send(owner, {:read_length, length})
      :file.pread(fd, offset, length)
    end

    assert {:ok, tail} = PageReader.tail(path, limit: 500, pread: pread)
    assert tail.more?
    lengths = read_lengths([])
    assert Enum.sum(lengths) <= 1_048_576 + 65_536 + 256
    assert length(tail.entries) < 260
    all = path |> older(tail, [tail]) |> Enum.flat_map(& &1.entries)
    assert Enum.map(all, & &1.body) == bodies
    assert {:ok, forward} = PageReader.since(path, "#{tail.gen}:0", limit: 500)
    assert forward.more?
    assert {:ok, next} = PageReader.since(path, forward.last, limit: 500)
    assert {:ok, final} = PageReader.since(path, next.last, limit: 500)
    assert Enum.map(forward.entries ++ next.entries ++ final.entries, & &1.body) == bodies
  end

  test "forward budget advances through a large open merge group", %{path: path} do
    File.write!(path, Enum.map(1..10_000, fn _ -> delta(String.duplicate("x", 120)) end))
    assert {:ok, tail} = PageReader.tail(path)
    assert {:ok, first} = PageReader.since(path, "#{tail.gen}:0")
    assert first.more?
    refute first.last == "#{tail.gen}:0"
    pages = forward_pages(path, first, [first])
    body = pages |> Enum.flat_map(& &1.entries) |> Enum.map_join(& &1.body)
    assert body == String.duplicate("x", 1_200_000)
  end

  defp forward_pages(_path, %{more?: false}, pages), do: Enum.reverse(pages)

  defp forward_pages(path, page, pages) do
    assert {:ok, next} = PageReader.since(path, page.last)
    if next.more?, do: assert(next.last != page.last)
    forward_pages(path, next, [next | pages])
  end

  defp read_lengths(acc) do
    receive do
      {:read_length, length} -> read_lengths([length | acc])
    after
      0 -> acc
    end
  end

  defp older(_path, %{more?: false}, pages), do: pages

  defp older(path, page, pages) do
    assert {:ok, previous} = PageReader.before(path, page.first, limit: 17)
    older(path, previous, [previous | pages])
  end

  defp line(text), do: Jason.encode!(%{method: "item/completed", params: %{item: %{type: "agentMessage", text: text}}}) <> "\n"
  defp delta(text), do: Jason.encode!(%{method: "item/agentMessage/delta", params: %{itemId: "a", delta: text}}) <> "\n"
  defp completed(text), do: Jason.encode!(%{method: "item/completed", params: %{item: %{type: "agentMessage", id: "a", text: text}}}) <> "\n"
end
