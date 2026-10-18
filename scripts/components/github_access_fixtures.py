"""Exercise the access-to-domain boundary and its dependency mutation."""
import json


def run(check):
    from .github_access_ownership import check as ownership_check
    ownership_check()
    fixture = 'access_to_domain_fails'
    check(fixture, fixture, 1, ('R-declared github-access -> B.Facade',))

    def declare_domain(root):
        path = root / 'components.json'
        manifest = json.loads(path.read_text())
        manifest['components'][0]['requires'].append('github')
        path.write_text(json.dumps(manifest))

    check('access_to_domain_declared_passes', fixture, change=declare_domain)
    check('access_domain_doc_mentions_ignored', fixture,
          source='defmodule A do\n  @moduledoc "Calls B.Facade in the domain."\n  # B.Facade.read()\n  def read, do: :ok\nend\n',
          messages=('R-declared: 0',))
