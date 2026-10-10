defmodule Aiur.AgentProcessLog.Rows do
  @moduledoc false

  # The process tree walk, its start/exit diff, and the TSV row shapes.

  # The argv allowlist: only this many leading tokens of a command line are ever
  # examined. Each token is then kept verbatim only if it matches a known-safe
  # shape (`safe_token?/1`); credentials live anywhere in argv, so the per-token
  # allowlist — not a denylist of "known credential shapes" — is the real
  # security boundary, and this cap bounds the recorded row size.
  @max_argv_tokens 8

  # Returns `{tree, tickets}` where `tree` is `%{pid => %{root_pid, ppid, comm,
  # cmdline, cwd, start_time}}` for every process under every registered agent
  # root and `tickets` maps the root pid to its reaper `ticket` meta.
  def observe_tree(state) do
    roots = state.roots_fun.()
    tickets = Map.new(roots, fn {root_pid, ticket} -> {root_pid, ticket} end)
    all = state.processes_fun.()
    index = children_index(all)

    {tree, _claimed} =
      Enum.reduce(roots, {%{}, %{}}, fn {root_pid, _ticket}, {tree, claimed} ->
        walk_root(root_pid, index, all, state.cwd_fun, tree, claimed)
      end)

    {tree, tickets}
  end

  # `%{ppid => [pid, ...]}` so each sweep walks the tree with no per-process
  # subprocess spawns.
  defp children_index(all) do
    Enum.reduce(all, %{}, fn {pid, info}, acc ->
      ppid = Map.get(info, :ppid, 0)
      Map.update(acc, ppid, [pid], &[pid | &1])
    end)
  end

  defp walk_root(root_pid, index, all, cwd_fun, tree, claimed) do
    {tree, claimed} =
      put_process(tree, claimed, root_pid, root_pid, 0, Map.get(all, root_pid), cwd_fun)

    walk_queue([root_pid], MapSet.new([root_pid]), root_pid, index, all, cwd_fun, tree, claimed)
  end

  defp walk_queue([], _seen, _root, _index, _all, _cwd_fun, tree, claimed), do: {tree, claimed}

  defp walk_queue([pid | rest], seen, root, index, all, cwd_fun, tree, claimed) do
    {tree, claimed, seen, children} =
      Enum.reduce(Map.get(index, pid, []), {tree, claimed, seen, []}, fn child_pid, acc ->
        if MapSet.member?(elem(acc, 2), child_pid) do
          acc
        else
          {tree, claimed} =
            put_process(elem(acc, 0), elem(acc, 1), child_pid, root, pid, Map.get(all, child_pid), cwd_fun)

          {tree, claimed, MapSet.put(elem(acc, 2), child_pid), [child_pid | elem(acc, 3)]}
        end
      end)

    walk_queue(rest ++ children, seen, root, index, all, cwd_fun, tree, claimed)
  end

  # Adds `pid` to the tree under `root_pid` (the registered agent root of the
  # walk) with `ppid` from the walk. `claimed` (`%{pid => root_pid}`) and
  # `Map.put_new` keep the first root that claims a pid, so a child that ends
  # up reachable from two registered roots (nested roots, re-parenting) is
  # attributed once.
  defp put_process(tree, claimed, pid, root_pid, ppid, info, cwd_fun) do
    case info do
      %{comm: comm} ->
        claimed = Map.put_new(claimed, pid, root_pid)

        tree =
          Map.put_new(tree, pid, %{
            root_pid: root_pid,
            ppid: ppid,
            pid: pid,
            comm: comm,
            cmdline: Map.get(info, :cmdline, ""),
            start_time: Map.get(info, :start_time),
            cwd: cwd_fun.(pid)
          })

        {tree, claimed}

      nil ->
        {tree, claimed}
    end
  end

  def diff_processes(previous, seen) do
    starts =
      seen
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(previous, &1))
      |> Map.new(&{&1, seen[&1]})

    exits =
      previous
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(seen, &1))
      |> Map.new(&{&1, previous[&1]})

    {starts, exits}
  end

  def start_row(now, entry) do
    {argv, argv_sha} = argv_record(entry.cmdline)

    join([
      unix(now),
      "start",
      entry.root_pid,
      entry.ticket || "",
      entry.pid,
      entry.ppid,
      entry.comm,
      argv,
      argv_sha,
      entry.cwd,
      ""
    ])
  end

  def exit_row(now, entry) do
    duration =
      case Map.get(entry, :first_seen) do
        %DateTime{} = first -> max(DateTime.diff(now, first, :second), 0)
        _unknown -> ""
      end

    join([
      unix(now),
      "exit",
      entry.root_pid,
      entry.ticket || "",
      entry.pid,
      entry.ppid,
      entry.comm,
      "",
      "",
      "",
      duration
    ])
  end

  defp unix(now), do: Integer.to_string(DateTime.to_unix(now))

  # Every cell is escaped so an arbitrary byte in a recorded field (a literal
  # newline in cwd, a tab, a backslash) cannot break the line structure or
  # forge a fake row. argv itself is already whitespace-normalized by
  # `argv_record`, so the escaping is what protects the verbatim fields and is
  # defense-in-depth for every other cell. Backslash first, then the control
  # characters, so the encoding is round-trippable and a literal backslash is
  # never confused with an escape.
  defp join(fields) do
    Enum.map_join(fields, "\t", fn field ->
      field
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\t", "\\t")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
    end)
  end

  # The argv allowlist. Each of the first `@max_argv_tokens` tokens is recorded
  # verbatim only if it matches a known-safe shape; every other token — a
  # credential in any encoding, a URL, a `KEY=value`, or a bare positional
  # word — is replaced by `<redacted>`. When the command line is longer than
  # the token cap, the tail is never recorded at all. Whenever the recorded
  # argv is lossy (a redacted token, or a dropped tail), the whole line is
  # reduced to a SHA-256 fingerprint so identical invocations can still be
  # correlated without reproducing their content.
  defp argv_record(cmdline) when is_binary(cmdline) and cmdline != "" do
    tokens = String.split(cmdline, ~r/\s+/, trim: true)
    {kept, dropped} = Enum.split(tokens, @max_argv_tokens)

    {shown, redacted?} =
      Enum.map_reduce(kept, false, fn token, redacted? ->
        if safe_token?(token) do
          {token, redacted?}
        else
          {"<redacted>", true}
        end
      end)

    shown = Enum.join(shown, " ")

    case {dropped, redacted?} do
      {[], false} -> {shown, ""}
      {[], true} -> {shown, argv_fingerprint(cmdline)}
      {_tail, _redacted} -> {shown <> " <...>", argv_fingerprint(cmdline)}
    end
  end

  defp argv_record(_other), do: {"", ""}

  defp argv_fingerprint(cmdline) do
    :crypto.hash(:sha256, cmdline) |> Base.encode16(case: :lower)
  end

  # A token is recorded only when its shape cannot carry a credential. Two
  # shapes qualify: a bare dash flag (`-S`, `--verbose` — never a `--key=value`
  # form) and a filesystem path (`/ws/…`, `./mix.exs`, `../deps/…`). Everything
  # else — including any bare word, because a bare positional secret is
  # indistinguishable from a benign word — is treated as potentially sensitive
  # and redacted. The length cap keeps a pathological flag or path from
  # bloating a row; paths past it are simply not reproduced.
  @safe_flag ~r/\A--?[A-Za-z0-9][A-Za-z0-9_-]*\z/
  @safe_path ~r{\A(?:/|\./|\.\./)[A-Za-z0-9_./~-]+\z}
  @safe_token_max_bytes 1024

  defp safe_token?(token) do
    byte_size(token) <= @safe_token_max_bytes and
      (Regex.match?(@safe_flag, token) or Regex.match?(@safe_path, token))
  end
end
