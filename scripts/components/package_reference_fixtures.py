"""Ensure package production files participate in the Elixir boundary scan."""
import json


def run(check):
    def move_to_package(root):
        manifest_path = root / 'components.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['components'][0]['paths'] = ['packages/elixir/example/lib/a.ex']
        manifest_path.write_text(json.dumps(manifest))
        source = root / 'src/lib/a.ex'
        target = root / 'packages/elixir/example/lib/a.ex'
        target.parent.mkdir(parents=True)
        source.replace(target)

    check('package_reference_undeclared_fails', 'undeclared_dependency_fails', 1,
          ('R-declared a -> B.Facade',), change=move_to_package)
