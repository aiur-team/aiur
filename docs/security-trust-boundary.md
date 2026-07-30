# GitHub trust boundary

Aiur uses `.github/CODEOWNERS` to determine which GitHub accounts own review
routing and whose review or issue comments may be trusted as agent input. The
daemon exposes the resolved set and its source in `aiurdev status`, and raises
a needs-attention alert when the file is missing, empty, or unparseable.

`CODEOWNERS` is not a label-permission control. It does not restrict who may
apply GitHub labels: that is governed by GitHub's triage-and-higher repository
permissions. Review routing/comment trust and label application are unrelated
GitHub systems and must not be conflated when evaluating dispatch security.

For this repository, the CODEOWNERS set should converge with the configured
GitHub dispatch `allowed_users` set. The two mechanisms remain separate: the
former controls review/comment trust, while the latter authorizes issue
dispatch provenance.
