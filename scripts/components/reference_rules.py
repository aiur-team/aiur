"""Structural rules and informational cycles over resolved component edges."""

RULES = ('R-declared', 'R-private', 'R-down', 'R-optional')


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
        indices[start] = low[start] = len(indices)
        stack.append(start)
        active.add(start)
        frames = [(start, iter(sorted(graph[start])))]
        while frames:
            node, children = frames[-1]
            child = next(children, None)
            if child is not None:
                if child not in indices:
                    indices[child] = low[child] = len(indices)
                    stack.append(child)
                    active.add(child)
                    frames.append((child, iter(sorted(graph[child]))))
                elif child in active:
                    low[node] = min(low[node], indices[child])
                continue
            frames.pop()
            if low[node] == indices[node]:
                group = []
                while True:
                    member = stack.pop()
                    active.remove(member)
                    group.append(member)
                    if member == node:
                        break
                groups.append(sorted(group))
            if frames:
                parent = frames[-1][0]
                low[parent] = min(low[parent], low[node])
    return sorted(groups, key=lambda group: (-len(group), group))


def report_cycles(graph):
    for group in strongly_connected(graph):
        print(f'scc: {len(group)} components: {group}')
