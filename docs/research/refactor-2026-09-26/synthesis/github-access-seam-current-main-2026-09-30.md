# GitHub access seam at `main@b4bc11f`

Two independent read-only reviews checked KTD11 against detached
`b4bc11ffcb6abf693bb3c8570aca3e12d82cb24f` after reading
`website/docs-app/apis/github.md`. This is a source contract, not an
incidence measurement or a tested migration.

The first seam already exists in process. `Aiur.Application` uses
`rest_for_one` and starts App token refresh, credential headroom, read cache,
quota, resource state and publisher in dependency order (`src/lib/aiur.ex:82-115,324-384`).
`Transport` selects the credential before its read cache and wraps quota and
budget admission inside the cache (`github/transport.ex:94-119,154-215`).
`ResourceFetch.need/3` already names held, revalidated and fetched outcomes
(`github/resource_fetch.ex:68-132,182-203`). Keep that seam and prove its
outcomes before changing callers; a new process or package has no source-backed
benefit yet.

| Current-main risk | Evidence | Focused proof before migration |
| --- | --- | --- |
| A one-page response can masquerade as a complete list. | `Transport.fetch_json_list/4` returns a 200 list without checking `rel="next"` (`github/transport.ex:676-690`), while its conditional sibling refuses pagination (`:708-739`). Classified comments and PR changed paths use the one-page helper (`github/comments.ex:124-139`, `github/pull_requests.ex:13-27`). | Supply 101+ comments or paths and a real-shaped next link, including an owned path on page two and a page-two failure. Require all pages or an explicit incomplete result before using them for trust/ownership. Preserve request caller attribution and ETag rules. |
| A fetched body and an accepted store deposit are different facts. | `ResourceFetch.store/4` unconditionally deposits a fetched body then reports `:fetched` (`github/resource_fetch.ex:206-227`); `ResourceStore.put_resource/3` returns `:ok` for a nil key or abandoned write (`github/resource_store.ex:711-719,1476-1487`). A delayed older 200 can race a newer webhook deposit. | Hold a fetch, deposit a newer webhook version, then release the fetch. Assert monotonic held body and an outcome that does not claim retention when the store is unavailable or drops the write. Compare the separate issue path (`github/issues.ex:296-323`). |
| Restart and credential assumptions bound the contract. | `ResourceStore` checkpoints periodically, with a crash window (`github/resource_store.ex:1297-1316,1914-1935`); cache/headroom tables reset on restart (`github/read_cache.ex:242-249`, `github/credential_headroom.ex:145-150`). Cache keys omit credential by an explicit equal-visibility assumption (`github/transport.ex:103-114`), and `ModeRegistry` can leave a stale mode-table entry until the next sweep (`src/lib/aiur.ex:376-383`). | Crash each owner under `rest_for_one`; assert fallback read, quota admission, freshness and mode behavior. Distinguish graceful checkpoint recovery from an unflushed crash. Verify equal visibility or reject mixed-visibility credentials. |
| Mutations have an ambiguous remote outcome. | A transport deadline can arrive after GitHub applied a mutation (`github/transport.ex:13-18,382-440`); the review-reply path retries retryable errors (`github/review_threads/reply.ex:55-95`). | Inject applied mutation plus lost response, then restart; reconcile by remote identity before retry so a reply is posted once. |

The seam should align `complete`, `held`, and `unknown` at existing access
entries while retaining the exact caller, token, pagination, ETag, quota and
startup contracts. `ResourceStore`'s checkpoint cadence means an in-memory
deposit is not proof that the latest observation survives an immediate daemon
crash. Keep the documented raw `Req` PAT-validation exception
(`github/config.ex:252-258`); do not claim that every GitHub request passes
through `Transport`.
