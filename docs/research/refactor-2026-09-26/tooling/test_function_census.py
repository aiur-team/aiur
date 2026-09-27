#!/usr/bin/env python3
"""Exercise census semantics on synthetic syntax, without compiling fixtures."""
import json
from pathlib import Path
import subprocess
import tempfile
from function_census_summary import summarize

with tempfile.TemporaryDirectory(prefix='aiur-census-check-') as temp:
    root = Path(temp)
    (root / 'src/lib').mkdir(parents=True)
    source = '''defmodule Example do
  def guarded(value) when is_binary(value) do
    case value do
      "" -> nil
      other -> other
    end
  end
  def alternate(value) when is_integer(value) do
    case value do
      "" -> nil
      other -> other
    end
  end
  defdelegate delegate(value), to: Other
  defmodule Inner do
    def same(value) do
      case value do
        "" -> nil
        other -> other
      end
    end
  end
  def after_nested(), do: :ok
  quote do
    def not_runtime(), do: :ignored
  end
end
'''
    (root / 'src/lib/fixture.ex').write_text(source)
    def census():
        return json.loads(subprocess.check_output(['elixir', str(Path(__file__).with_name('function_census.exs')), str(root)], text=True))
    data = census()
    rows = {row['name']: row for row in data['definitions']}
    assert set(rows) == {'guarded', 'alternate', 'delegate', 'same', 'after_nested'}
    assert rows['same']['module'] == 'Example.Inner'
    assert rows['after_nested']['module'] == 'Example'
    assert rows['guarded']['arity'] == 1 and rows['delegate']['kind'] == 'defdelegate'
    assert rows['guarded']['line'] == 2 and rows['guarded']['end_line'] == 7
    assert rows['guarded']['body_sha256'] == rows['alternate']['body_sha256'] == rows['same']['body_sha256']
    assert summarize(data)['body_candidate_clusters'] == 1
    # Whitespace/line metadata do not change a candidate; a literal change does.
    (root / 'src/lib/fixture.ex').write_text('\n\n' + source)
    shifted = {row['name']: row for row in census()['definitions']}
    assert shifted['guarded']['body_sha256'] == rows['guarded']['body_sha256']
    (root / 'src/lib/fixture.ex').write_text(source.replace('"" -> nil', '"" -> :missing', 1))
    changed = {row['name']: row for row in census()['definitions']}
    assert changed['guarded']['body_sha256'] != rows['guarded']['body_sha256']
    assert changed['alternate']['body_sha256'] == rows['alternate']['body_sha256']
print('Census fixture checks passed: module scope, clauses, guards, quote exclusion, metadata stability and literal sensitivity.')
