defmodule Aiur.GitHub.FreeProbeBudgetTest do
  use ExUnit.Case, async: true

  test "free probe passes a spent core ceiling while paid requests stay held" do
    broker = Path.expand("../../../priv/github_budget.py", __DIR__)

    script = """
    import importlib.util, sqlite3, sys
    from types import SimpleNamespace
    spec = importlib.util.spec_from_file_location('budget', sys.argv[1])
    broker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(broker)
    conn = sqlite3.connect(':memory:')
    conn.execute('CREATE TABLE admissions (token_key, consumer_key, resource, billable, admitted_at_ms)')
    conn.execute("INSERT INTO admissions VALUES ('fixture', 'daemon', 'core', 1, 1000)")
    args = SimpleNamespace(token_key='fixture', consumer_key='daemon', resource='none',
                           core_limit=1, graphql_limit=1, search_limit=1)
    print(broker.actor_ceiling_hold(conn, args, 2000))
    args.resource = 'core'
    print(broker.actor_ceiling_hold(conn, args, 2000))
    """

    assert {"0\n3599000\n", 0} = System.cmd("python3", ["-B", "-c", script, broker])
  end
end
