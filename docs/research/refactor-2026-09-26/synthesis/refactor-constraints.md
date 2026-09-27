# Refactor constraints

## File size and modular decomposition

User requirement added 2026-09-27:

- Hard limit: files must not exceed 500 lines.
- Preferred target: keep files at or below 200 lines.
- Break large components into smaller, cohesive modules with explicit responsibilities and interfaces; moving arbitrary line ranges into helper files does not satisfy the modularity requirement.
- Carry these limits into the final rewrite requirements, package decomposition, implementation units and acceptance criteria.
- The implementation plan must inventory oversized files, assign their decomposition to owning components, and include automated enforcement of the 500-line limit. Treat 200 lines as a design/review preference.
- Define the line-counting convention and handling of generated or vendored artifacts explicitly in the plan; no exceptions to the user's hard limit have been authorized.

This records a future refactor requirement, not evidence that the current codebase meets it.
