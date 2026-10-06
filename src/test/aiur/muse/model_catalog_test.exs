defmodule Aiur.Muse.ModelCatalogTest do
  use ExUnit.Case, async: false

  alias Aiur.Muse.ModelCatalog

  test "native IDs preserve catalog order without inventing defaults or aliases" do
    assert {:ok, ["native-b", "native-a"]} =
             ModelCatalog.extract(%{"models" => [%{"modelId" => "native-b"}, %{"modelId" => "native-a"}, %{"modelId" => "native-b"}]})

    assert {:ok, []} = ModelCatalog.extract(%{"models" => []})
    assert {:error, :invalid_muse_model_catalog} = ModelCatalog.extract(%{"models" => [%{"modelId" => nil}]})
    assert {:error, :invalid_muse_model_catalog} = ModelCatalog.extract(%{"data" => []})
  end

  @tag :tmp_dir
  test "probe completes native initialization before discovery and makes no turn request", %{tmp_dir: workspace} do
    script = Path.join(workspace, "native fixture.py")

    File.write!(script, """
    import sys,json
    initialized=False
    for line in sys.stdin:
      frame=json.loads(line)
      method=frame['method']
      if method=='initialize':
        result={'grantedCapabilities':['sessionMcp'],'schema':{'version':1}}
      elif method=='initialized':
        initialized=True
        continue
      elif method=='model/list' and initialized:
        result={'models':[{'modelId':'native-model'}]}
      else:
        sys.exit(29)
      print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':result}),flush=True)
    """)

    python = System.find_executable("python3") || raise "python3 required for protocol fixture"
    command = Aiur.Shell.escape(python) <> " -u " <> Aiur.Shell.escape(script)

    assert {:ok, ["native-model"]} =
             Aiur.ModelCatalog.discover("muse", workspace: workspace, config: %{"command" => command}, timeout_ms: 5_000)
  end
end
