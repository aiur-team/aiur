# Classify without compiling the app; the fast job expands xref and deleted names.
paths = System.argv() |> hd() |> File.read!() |> String.split("\n", trim: true)

case Aiur.AffectedTests.select(paths) do
  {:full, _reason} -> IO.puts("full")
  {:scoped, tests} -> IO.puts("scoped:#{length(tests)}")
end
