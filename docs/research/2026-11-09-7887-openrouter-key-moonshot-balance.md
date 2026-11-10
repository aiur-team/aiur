# PCP-2 spike: OpenRouter per-key limit and Moonshot balance

Ticket #7887, part of #7881. Plan: [`docs/plans/2026-11-08-7881-provider-capacity-policy.md`](../plans/2026-11-08-7881-provider-capacity-policy.md),
section 3. Probed 2026-11-09.

**Result: both are pollable.** Each endpoint exists: it answers 401 without credentials, while an unknown path
on the same host answers 404. Both are documented with the fields below. **No authenticated response was
captured.** The agent workspace has neither `OPENROUTER_API_KEY` nor `MOONSHOT_API_KEY`, because Aiur removes
provider keys from agent environments. The spike did
not read the operator's dotenv to work around that removal. The field shapes below therefore come
from the providers' documented examples. The operator check at the end confirms them against a live key.

## OpenRouter: `GET https://openrouter.ai/api/v1/key`

- **Auth:** `Authorization: Bearer <key>`. This is the inference key the claim uses (`OPENROUTER_API_KEY`),
  not the management key that `/credits` needs. The endpoint describes the key it is called with.
- **Rate limit:** the endpoint has a per-IP burst limit and sends no `X-RateLimit-*` headers.
- **Fields under `data` (all USD):**
  - `limit` and `limit_remaining`: `null` means the key is unlimited.
  - `limit_reset`: the reset **type** (`"monthly"` in the example), or `null` for never. It gives no time.
  - `usage`, `usage_daily`, `usage_weekly`, `usage_monthly`: daily and monthly are UTC; weekly runs Monday to
    Sunday.
  - `budgets[]`: every budget layer in enforcement order, as `{scope, limit_usd, spend_usd, remaining_usd,
    reset_interval, resets_at}`. Scopes include `key_limit`, `member` and `workspace`.
  - `effective_budget`: the budget that blocks first, or `null`. **This is the field that carries the reset
    time** (`resets_at`). The policy should read it rather than `limit_remaining`, because a workspace or
    member budget can block before the key limit does.
  - `rate_limit` is deprecated and documented as meaningless. Do not use it.
- **Unauthenticated probe (captured 2026-11-09):**

  ```text
  GET /api/v1/key                 -> HTTP/2 401  {"error":{"message":"No cookie auth credentials found","code":401}}
  GET /api/v1/nonexistent-xyz     -> HTTP/2 404
  ```

- **Documented example** ([API reference](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-key),
  abridged and redacted):

  ```json
  {"data": {"label": "sk-or-v1-…", "limit": 100, "limit_remaining": 74.5, "limit_reset": "monthly",
            "usage": 25.5, "usage_daily": 25.5, "usage_weekly": 25.5, "usage_monthly": 25.5,
            "is_free_tier": false, "is_management_key": false,
            "budgets": [{"scope": "member", "limit_usd": 50, "spend_usd": 32.5, "remaining_usd": 17.5,
                         "reset_interval": "weekly", "resets_at": "2026-10-12T00:00:00.000Z"}],
            "effective_budget": {"scope": "member", "remaining_usd": 17.5, "resets_at": "2026-10-12T00:00:00.000Z"},
            "rate_limit": {"requests": 1000, "interval": "1h"}}}
  ```

- **Still unknown:** request-rate limits. The docs give no per-key RPM except the fixed limits for free models
  (20 per minute; 50 or 1000 per day).

## Moonshot / Kimi: `GET https://api.moonshot.ai/v1/users/me/balance`

- **Auth:** `Authorization: Bearer $MOONSHOT_API_KEY`. Keys from `.ai` and `.cn` (`platform.kimi.com`) are
  separate: a key works only on its own host. `api.moonshot.cn` serves the same path.
- **Fields under `data` (all USD):**
  - `available_balance`: cash plus vouchers. At `<= 0` inference fails with `exceeded_current_quota_error`.
  - `voucher_balance`: never negative.
  - `cash_balance`: may go negative, meaning money is owed.
- **Unauthenticated probe (captured 2026-11-09):**

  ```text
  GET api.moonshot.ai/v1/users/me/balance -> HTTP/2 401 {"error":{"message":"Incorrect API key provided","type":"incorrect_api_key_error"}}
  GET api.moonshot.cn/v1/users/me/balance -> HTTP/2 401 (same body)
  GET api.moonshot.ai/v1/nonexistent-xyz  -> HTTP/2 404 {"code":5,"error":"url.not_found",...}
  ```

- **Documented example** ([balance API](https://platform.kimi.ai/docs/api/balance)):

  ```json
  {"code": 0, "data": {"available_balance": 49.58894, "voucher_balance": 46.58893, "cash_balance": 3.00001},
   "scode": "0x0", "status": true}
  ```

- **Still unknown:** rate limits and their resets. Limits are per user, not per key, and shared across models.
  They are set by cumulative-recharge tier ([limits](https://platform.kimi.ai/docs/pricing/limits)). No
  endpoint reports them, chat responses carry no rate-limit headers, and an exceeded limit shows only as a 429.
  The balance has no reset because it is prepaid.

## Operator check

Each endpoint needs one authenticated capture, run by an operator who holds the key:

```bash
curl -s -H "Authorization: Bearer $OPENROUTER_API_KEY" https://openrouter.ai/api/v1/key \
  | jq '.data | {limit, limit_remaining, limit_reset, usage_daily, usage_monthly, effective_budget}'
curl -s -H "Authorization: Bearer $MOONSHOT_API_KEY" https://api.moonshot.ai/v1/users/me/balance | jq .data
```

Add the redacted output under each section. Remove `label`, IDs and `creator_user_id`, keep the numbers, and
change the plan's evidence column from "documented" to "captured".
