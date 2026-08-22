defmodule Aiur.Prewarm.DetectTest do
  use ExUnit.Case, async: true

  alias Aiur.Prewarm.Detect

  describe "detect/1" do
    test "resolves the build ROOT to the manifest's dir, not the repo root (aiur trap)" do
      # aiur's real build is `src/mix.exs` behind a lockfile-less root
      # package.json. Naive "repo root" or "first package.json wins" both fail.
      root =
        tmp_repo(%{
          "package.json" => "{}",
          "src/mix.exs" => "defmodule X do end",
          "src/mix.lock" => "%{}"
        })

      assert {:ok, %{language: :elixir, build_root: "src", command: command}} = Detect.detect(root)
      assert command =~ "cd src && "
      assert command =~ "mix compile"
    end

    test "Node with pnpm-lock uses corepack + frozen pnpm install" do
      root = tmp_repo(%{"package.json" => "{}", "pnpm-lock.yaml" => ""})

      assert {:ok, %{language: :node, build_root: ".", command: command}} = Detect.detect(root)
      assert command =~ "corepack enable"
      assert command =~ "pnpm install --frozen-lockfile"
      refute command =~ "cd "
    end

    test "Node with package-lock uses npm ci" do
      root = tmp_repo(%{"package.json" => "{}", "package-lock.json" => "{}"})
      assert {:ok, %{language: :node, command: command}} = Detect.detect(root)
      assert command =~ "npm ci"
    end

    test "Node appends a build step only when package.json declares one" do
      with_build = tmp_repo(%{"package.json" => ~s({"scripts":{"build":"vite build"}}), "package-lock.json" => "{}"})
      assert {:ok, %{command: command}} = Detect.detect(with_build)
      assert command =~ "npm run build"

      without = tmp_repo(%{"package.json" => "{}", "package-lock.json" => "{}"})
      assert {:ok, %{command: command}} = Detect.detect(without)
      refute command =~ "run build"
    end

    test "Node npm workspaces build once from the workspace root" do
      root =
        tmp_repo(%{
          "package.json" => ~s({"workspaces":["packages/*"]}),
          "package-lock.json" => "{}",
          "packages/a/package.json" => ~s({"scripts":{"build":"tsc"}}),
          "packages/b/package.json" => "{}"
        })

      assert {:ok, %{language: :node, build_root: ".", command: command}} = Detect.detect(root)
      assert command =~ "npm ci"
      assert command =~ "npm run build --workspaces --if-present"
      refute command =~ "cd packages"
    end

    test "pnpm-workspace.yaml promotes the repo root even without a root package.json" do
      root =
        tmp_repo(%{
          "pnpm-workspace.yaml" => "packages:\n  - packages/*\n",
          "pnpm-lock.yaml" => "",
          "packages/a/package.json" => "{}"
        })

      assert {:ok, %{language: :node, build_root: ".", command: command}} = Detect.detect(root)
      assert command =~ "pnpm install --frozen-lockfile"
      assert command =~ "pnpm -r --if-present build"
    end

    test "Go builds with go mod download + go build" do
      root = tmp_repo(%{"go.mod" => "module x", "go.sum" => ""})
      assert {:ok, %{language: :go, command: command}} = Detect.detect(root)
      assert command =~ "go mod download"
      assert command =~ "go build ./..."
    end

    test "Rust builds with cargo build" do
      root = tmp_repo(%{"Cargo.toml" => "[package]", "Cargo.lock" => ""})
      assert {:ok, %{language: :rust, command: "mise exec -- cargo build"}} = Detect.detect(root)
    end

    test "Python with poetry.lock uses poetry install" do
      root = tmp_repo(%{"pyproject.toml" => "[tool.poetry]", "poetry.lock" => ""})
      assert {:ok, %{language: :python, command: command}} = Detect.detect(root)
      assert command =~ "poetry install"
    end

    test "Python with only requirements.txt uses pip install -r" do
      root = tmp_repo(%{"requirements.txt" => "flask\n"})
      assert {:ok, %{language: :python, command: command}} = Detect.detect(root)
      assert command =~ "pip install -r requirements.txt"
    end

    test "Node with yarn.lock uses corepack + immutable yarn" do
      root = tmp_repo(%{"package.json" => "{}", "yarn.lock" => ""})
      assert {:ok, %{command: command}} = Detect.detect(root)
      assert command =~ "corepack enable"
      assert command =~ "yarn install --immutable"
    end

    test "Node with bun.lockb uses bun install" do
      root = tmp_repo(%{"package.json" => "{}", "bun.lockb" => ""})
      assert {:ok, %{command: command}} = Detect.detect(root)
      assert command =~ "bun install"
    end

    test "Swift package builds with swift build" do
      root = tmp_repo(%{"Package.swift" => "// swift-tools-version:5.9", "Package.resolved" => "{}"})

      assert {:ok, %{language: :swift, build_root: ".", command: "mise exec -- swift build"}} =
               Detect.detect(root)
    end

    test "CocoaPods project installs pods" do
      root = tmp_repo(%{"Podfile" => "platform :ios", "Podfile.lock" => ""})

      assert {:ok, %{language: :cocoapods, command: "mise exec -- pod install"}} = Detect.detect(root)
    end

    test "vendored SwiftPM/CocoaPods trees are skipped, not detected" do
      # A node app whose Pods/ and .build/ carry their own manifests must still
      # resolve to the app's own toolchain, not the vendored ones.
      root =
        tmp_repo(%{
          "package.json" => ~s({"scripts":{"build":"vite build"}}),
          "package-lock.json" => "{}",
          "Pods/Some/Podfile" => "platform :ios",
          ".build/checkouts/dep/Package.swift" => "// swift"
        })

      assert {:ok, %{language: :node}} = Detect.detect(root)
    end

    test "no supported manifest -> :none" do
      assert :none = Detect.detect(tmp_repo(%{"README.md" => "hi"}))
    end

    test "two lockfile-backed languages at the same depth -> {:ambiguous, candidates}" do
      root =
        tmp_repo(%{
          "package.json" => "{}",
          "package-lock.json" => "{}",
          "go.mod" => "module x",
          "go.sum" => ""
        })

      assert {:ambiguous, candidates} = Detect.detect(root)
      langs = Enum.map(candidates, & &1.language)
      assert :node in langs
      assert :go in langs
      assert Enum.all?(candidates, &(&1.build_root == "."))
    end

    test "nx monorepo builds through the workspace orchestrator" do
      root = tmp_repo(%{"package.json" => "{}", "pnpm-lock.yaml" => "", "nx.json" => "{}"})

      assert {:ok, %{language: :node, build_root: ".", command: command}} = Detect.detect(root)
      assert command =~ "pnpm install --frozen-lockfile"
      assert command =~ "pnpm exec nx run-many -t build --all"
    end

    test "turbo monorepo builds through the workspace orchestrator" do
      root = tmp_repo(%{"package.json" => "{}", "package-lock.json" => "{}", "turbo.json" => "{}"})

      assert {:ok, %{language: :node, build_root: ".", command: command}} = Detect.detect(root)
      assert command =~ "npm ci"
      assert command =~ "npm exec -- turbo run build"
    end
  end

  defp tmp_repo(files) do
    root = Path.join(System.tmp_dir!(), "aiur_detect_#{System.pid()}-#{System.unique_integer([:positive])}")

    Enum.each(files, fn {rel, content} ->
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
