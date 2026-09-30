# Isolated oracle probe: no Aiur application, provider, tmux or production mutation.
[snapshot] = System.argv()
source = Path.join(snapshot, "src/test/aiur/claude/display_tailer_test.exs")
ast = source |> File.read!() |> Code.string_to_quoted!()
title = "forwards the full conversation (user, thinking, assistant, tool i/o) in order"
{_, tests} = Macro.prewalk(ast, [], fn
  {:test, _, [^title, _, [do: body]]} = node, acc -> {node, [body | acc]}
  node, acc -> {node, acc}
end)
[{:__block__, _, expressions}] = tests
assertions = Enum.filter(expressions, fn
  {:assert, _, _} = node ->
    {_, variables} = Macro.prewalk(node, [], fn
      {name, _, context} = variable, acc when name in [:forwarded, :roles] and is_atom(context) ->
        {variable, [name | acc]}
      other, acc -> {other, acc}
    end)
    variables != []
  _ -> false
end)
10 = length(assertions)
ordered = [
  {:user, "do the task"},
  {:reasoning, "I will check the dir"},
  {:assistant, "Let me look"},
  {:command, "ls -la"},
  {:tool, "total 8\nfile.ex"},
  {:assistant, "All done"}
]
evaluate = fn forwarded ->
  code = quote do
    import ExUnit.Assertions
    unquote_splicing(assertions)
  end
  Code.eval_quoted(code, forwarded: forwarded, roles: Enum.map(forwarded, &elem(&1, 0)))
  :pass
end
:pass = evaluate.(ordered)
:pass = evaluate.(Enum.reverse(ordered))
control = fn events -> events == ordered end
true = control.(ordered)
false = control.(Enum.reverse(ordered))
IO.puts("extracted_assertions=10")
IO.puts("original_order_passes=true")
IO.puts("reversed_order_also_passes=true")
IO.puts("exact_order_control_rejects_reverse=true")
