defmodule Aiur.OpencodeThemeTest do
  use ExUnit.Case, async: true

  alias Aiur.OpencodeTheme

  # The full `ensure_active/1` orchestrates two side effects against
  # user state: copy the bundled theme JSON to opencode's themes dir,
  # and merge `theme: "aiur"` into opencode's kv.json. We test the
  # safety predicates in isolation and the orchestration with the
  # paths pointed at a tmp dir so user state is never touched.

  describe "should_set_theme?/1" do
    test "true when kv.json file is missing entirely (fresh opencode install)" do
      assert OpencodeTheme.should_set_theme?(:enoent)
    end

    test "true when kv.json has no `theme` key (default opencode behavior)" do
      assert OpencodeTheme.should_set_theme?(%{"theme_mode" => "dark"})
    end

    test "true when current theme is opencode's built-in default 'opencode'" do
      assert OpencodeTheme.should_set_theme?(%{"theme" => "opencode"})
    end

    test "FALSE when user has selected a custom theme other than aiur" do
      # Critical safety property — never silently override the user's choice.
      refute OpencodeTheme.should_set_theme?(%{"theme" => "dracula"})
      refute OpencodeTheme.should_set_theme?(%{"theme" => "catppuccin-mocha"})
    end

    test "true when current theme is already 'aiur' (idempotent re-activation)" do
      # Re-running aiur --test should not consider already-aiur as a
      # custom theme to preserve — it's our theme, idempotent set is fine.
      assert OpencodeTheme.should_set_theme?(%{"theme" => "aiur"})
    end
  end

  describe "merge_theme/1" do
    test "adds theme key when absent without touching other state" do
      kv = %{"theme_mode" => "dark", "timestamps" => "show", "share_consent" => true}
      merged = OpencodeTheme.merge_theme(kv)

      assert merged["theme"] == "aiur"
      assert merged["theme_mode"] == "dark"
      assert merged["timestamps"] == "show"
      assert merged["share_consent"] == true
    end

    test "overrides only the theme key, never others" do
      kv = %{"theme" => "opencode", "theme_mode" => "dark", "scrollbar_visible" => false}
      merged = OpencodeTheme.merge_theme(kv)

      assert merged["theme"] == "aiur"
      assert merged["theme_mode"] == "dark"
      assert merged["scrollbar_visible"] == false
    end
  end

  describe "ensure_active/1 (full orchestration with tmp paths)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "aiur_theme_#{System.unique_integer([:positive])}")
      themes_dir = Path.join(tmp, "themes")
      kv_path = Path.join(tmp, "kv.json")
      File.mkdir_p!(themes_dir)

      on_exit(fn -> File.rm_rf!(tmp) end)

      %{tmp: tmp, themes_dir: themes_dir, kv_path: kv_path}
    end

    test "copies the bundled theme JSON to the themes dir", ctx do
      assert {:ok, :active} =
               OpencodeTheme.ensure_active(themes_dir: ctx.themes_dir, kv_path: ctx.kv_path)

      copied = Path.join(ctx.themes_dir, "aiur.json")
      assert File.exists?(copied)
      assert {:ok, parsed} = Jason.decode(File.read!(copied))
      # markdownBlockQuote points at the theme's textMuted-equivalent
      # step (`darkStep11` = #808080) so blockquote text reads as a
      # clean dim grey on the dark background.
      assert parsed["theme"]["markdownBlockQuote"]["dark"] == "darkStep11"
      assert parsed["theme"]["markdownBlockQuote"]["light"] == "lightStep11"
    end

    test "creates kv.json with theme key when state file is absent", ctx do
      assert {:ok, :active} =
               OpencodeTheme.ensure_active(themes_dir: ctx.themes_dir, kv_path: ctx.kv_path)

      assert {:ok, kv} = Jason.decode(File.read!(ctx.kv_path))
      assert kv["theme"] == "aiur"
    end

    test "preserves a user's custom theme choice without overwriting", ctx do
      original = %{
        "theme" => "dracula",
        "theme_mode" => "dark",
        "share_consent" => true
      }

      File.write!(ctx.kv_path, Jason.encode!(original))

      assert {:ok, :custom_theme_preserved} =
               OpencodeTheme.ensure_active(themes_dir: ctx.themes_dir, kv_path: ctx.kv_path)

      {:ok, kv} = Jason.decode(File.read!(ctx.kv_path))
      assert kv["theme"] == "dracula", "user's custom theme must NOT be overridden"
      assert kv["theme_mode"] == "dark"
      assert kv["share_consent"] == true
    end

    test "upgrades a default opencode theme to aiur (kv.json had `theme: opencode`)", ctx do
      File.write!(ctx.kv_path, Jason.encode!(%{"theme" => "opencode", "theme_mode" => "dark"}))

      assert {:ok, :active} =
               OpencodeTheme.ensure_active(themes_dir: ctx.themes_dir, kv_path: ctx.kv_path)

      {:ok, kv} = Jason.decode(File.read!(ctx.kv_path))
      assert kv["theme"] == "aiur"
      assert kv["theme_mode"] == "dark"
    end

    test "idempotent — running twice produces the same kv.json", ctx do
      {:ok, :active} = OpencodeTheme.ensure_active(themes_dir: ctx.themes_dir, kv_path: ctx.kv_path)
      first_kv = File.read!(ctx.kv_path)

      {:ok, :active} = OpencodeTheme.ensure_active(themes_dir: ctx.themes_dir, kv_path: ctx.kv_path)
      second_kv = File.read!(ctx.kv_path)

      assert first_kv == second_kv
    end

    test "skips instead of reporting success when config and state paths are not writable", ctx do
      blocked_config = Path.join(ctx.tmp, "blocked-config")
      blocked_state = Path.join(ctx.tmp, "blocked-state")
      File.write!(blocked_config, "not a directory")
      File.write!(blocked_state, "not a directory")

      themes_dir = Path.join(blocked_config, "opencode/themes")
      kv_path = Path.join(blocked_state, "opencode/kv.json")

      assert {:skipped, failures} =
               OpencodeTheme.ensure_active(themes_dir: themes_dir, kv_path: kv_path)

      refute failures == []
      assert {:themes_dir, ^themes_dir, _} = Enum.find(failures, &match?({:themes_dir, _, _}, &1))
      assert {:kv_read, ^kv_path, _} = Enum.find(failures, &match?({:kv_read, _, _}, &1))
    end
  end
end
