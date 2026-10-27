"""Render component-scoped boundary promotion debt."""


def validate_options(parser, args):
    """Validate the report's CLI option combinations."""
    if args.report != bool(args.component):
        parser.error('--report and --component must be used together')
    if args.report and (args.docs or args.format or args.prune or args.write_baseline or args.growth_base):
        parser.error('--report cannot be combined with docs, format, prune, baseline, or growth options')


def report(component, module_owners, violations, allowed):
    """Print live and stale exemption keys touching a component in either direction."""
    rows = []
    for rule, source, target in allowed:
        direction = 'outbound' if source == component else 'inbound'
        if source == component or module_owners.get(target) == component:
            rows.append((direction, rule, source, target,
                         'live' if (rule, source, target) in violations else 'stale'))
    print(f'components: promotion debt for {component}:')
    print('direction\trule\tsource component\ttarget module\tstatus')
    for row in sorted(set(rows)):
        print('\t'.join(row))


def run(root, manifest, component, rules, source_files, ownership, module_violations, read_allowlist):
    """Build and print the live/stale promotion boundary census."""
    files = source_files(root)
    problems, _, owners = ownership(manifest, files)
    if problems:
        raise ValueError('cannot report component debt with invalid ownership')
    components = {entry['id'] for entry in manifest['components']}
    if component not in components:
        raise ValueError(f'unknown component {component}')
    violations, _, modules = module_violations(root, manifest, owners, include_modules=True)
    violations = {key: value for key, value in violations.items() if key[0] in rules}
    allowed = read_allowlist(root, manifest)
    report(component, modules, violations, allowed)
