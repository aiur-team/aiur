"""Structural rules and informational cycles over resolved component edges."""
import fnmatch

RULES = ('R-declared', 'R-private', 'R-down', 'R-optional')
STRICT_RULES = ('R-forbid', 'R-seam')


def module_matches(pattern, target):
    return target == pattern or (pattern.endswith('.*') and target.startswith(pattern[:-1]))


def seam_rules(manifest, component, target, kind, path):
    rules = []
    if any(module_matches(pattern, target) for pattern in component.get('forbid', [])):
        rules.append('R-forbid')
    seams = [edge for edge in manifest.get('seams', [])
             if edge['from'] == component['id'] and module_matches(edge['to_module'], target)]
    matching = [edge for edge in seams if edge['kind'] == kind and
                ('only_paths' not in edge or any(fnmatch.fnmatchcase(path, pattern)
                                               for pattern in edge['only_paths']))]
    # Scoped adapters restrict even otherwise-declared, same-component references.
    if any('only_paths' in edge for edge in seams) and not matching:
        rules.append('R-seam')
    return rules, bool(matching)


def edge_rules(component, provider, target):
    rules = []
    if provider['id'] not in component['requires'] + component['optional']:
        rules.append('R-declared')
    if provider['facades'] != ['*'] and target not in provider['facades']:
        rules.append('R-private')
    if provider['layer'] > component['layer']:
        rules.append('R-down')
    if component['kind'] == 'required' and provider['kind'] == 'optional':
        rules.append('R-optional')
    return rules


def strongly_connected(graph):
    """Iterative Tarjan: cycles are legal and graphs need no recursion limit."""
    indices, low, active, stack, groups = {}, {}, set(), [], []
    for start in sorted(graph):
        if start in indices:
            continue
        frames = []
        enter(start, graph, frames, indices, low, active, stack)
        traverse(graph, frames, indices, low, active, stack, groups)
    return sorted(groups, key=lambda group: (-len(group), group))


def enter(node, graph, frames, indices, low, active, stack):
    indices[node] = low[node] = len(indices)
    stack.append(node)
    active.add(node)
    frames.append((node, iter(sorted(graph[node]))))


def traverse(graph, frames, indices, low, active, stack, groups):
    while frames:
        node, children = frames[-1]
        child = next(children, None)
        if child is not None and child not in indices:
            enter(child, graph, frames, indices, low, active, stack)
        elif child in active:
            low[node] = min(low[node], indices[child])
        if child is not None:
            continue
        frames.pop()
        if low[node] == indices[node]:
            groups.append(drain_component(node, stack, active))
        if frames:
            parent = frames[-1][0]
            low[parent] = min(low[parent], low[node])


def drain_component(node, stack, active):
    group = []
    while True:
        member = stack.pop()
        active.remove(member)
        group.append(member)
        if member == node:
            return sorted(group)


def report_cycles(graph):
    groups = strongly_connected(graph)
    for group in groups:
        print(f'scc: {len(group)} components: {group}')
    return max((len(group) for group in groups), default=0)
