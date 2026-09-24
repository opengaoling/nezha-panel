---
trigger: always_on
description: Mandatory Playwright browser verification after UI, auth, or frontend modifications.
---

# Mandatory Playwright Verification Rule

## Guideline
Whenever modifications are made to:
1. Frontend UI components, templates, styles, or scripts (`cmd/dashboard/user-dist`, `cmd/dashboard/admin-dist`)
2. Security gateway login card (`#gw-login-gate`), themes, or disguise layers
3. Authentication guards (`custom-auth-guard.js`, `custom-front-login.js`)
4. URL routing, redirect handling (e.g., `?redirect=` logic), or anti-bounce loops
5. White screen auto-recovery mechanisms or tab wakeup logic

**You MUST execute Playwright end-to-end verification before marking the task complete:**

```bash
python3 /home/ubuntu/playwright_verification/verify_with_playwright.py
```

### Verification Criteria
- All 12/12 test scenarios must PASS.
- Unauthenticated access to `/dashboard/` must cleanly redirect to `/?redirect=` and render `#gw-login-gate`.
- Submitting valid credentials must automatically enter `/dashboard/` without bouncing back.
- No console JavaScript `SyntaxError` or runtime exceptions.
- React root `#root` must not remain blank or white-screened.
- No `nz-` brand leakages in client DOM or visible elements.
