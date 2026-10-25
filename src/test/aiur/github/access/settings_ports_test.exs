defmodule Aiur.GitHub.Access.SettingsPortsTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.Access.{Settings, StaticSettings}
  alias Aiur.GitHub.Transport.TestScope

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    prior = Enum.map([:github_access_settings_provider, :github_access_settings], &{&1, Application.fetch_env(:aiur, &1)})
    on_exit(fn -> Aiur.TestSupport.restore_app_env(prior) end)
    Application.put_env(:aiur, :github_access_settings_provider, StaticSettings)
    %{root: root}
  end

  test "request taggers run in order inside the configured write scope", %{root: root} do
    taggers = [&Map.update(&1, :caller, "a", fn caller -> caller <> "a" end), &Map.update!(&1, :caller, fn caller -> caller <> "b" end)]
    scope = fn request, fun -> {:scoped, request.url, fun.()} end
    Application.put_env(:aiur, :github_access_settings, Settings.new(root, request_taggers: taggers, write_scope: scope))

    assert {:scoped, "u", %{caller: "ab"}} = TestScope.run(%{url: "u"}, & &1)
  end

  test "default settings leave the request untagged and unscoped", %{root: root} do
    Application.put_env(:aiur, :github_access_settings, Settings.new(root))
    request = Aiur.GitHub.Transport.put_caller(%{url: "u"}, caller: :standalone)
    assert %{url: "u", caller: "standalone"} == TestScope.run(request, & &1)
  end
end
