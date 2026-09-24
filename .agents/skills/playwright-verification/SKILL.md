---
name: playwright-verification
description: >-
  Automated Playwright end-to-end UI and authentication verification suite for the Nezha Monitoring Dashboard.
  Use this skill whenever changes are made to frontend assets, login gates, security disguise layers, routing,
  white screen auto-recovery, or session handling to verify functionality in a real browser.
---

# Playwright E2E Verification Skill

This skill provides an automated, browser-based end-to-end testing workflow for the Nezha Monitoring Dashboard using Playwright.

## Why Use This Skill

Whenever changes are made to:
- Frontend HTML, CSS, or JS in `cmd/dashboard/user-dist` or `cmd/dashboard/admin-dist`
- Security gateway login disguises (`#gw-login-gate`)
- Authentication guards (`custom-auth-guard.js`, `custom-front-login.js`)
- URL redirect and routing logic (e.g., `?redirect=` bounce handling)
- White screen auto-recovery guards
- Branding compliance (ensuring no `nz-` brand leakages)

**You MUST execute this Playwright verification suite to confirm that changes render and function properly without errors or infinite loops.**

---

## Quick Execution

Run the automated verification suite with:

```bash
python3 /home/ubuntu/playwright_verification/verify_with_playwright.py
```

Optional environment variables:
- `BASE_URL`: defaults to `http://127.0.0.1:2052`
- `SECRET`: secret path prefix, defaults to `mKovrigH`
- `ADMIN_USER`: admin username, defaults to `admin`
- `ADMIN_PASS`: admin password, defaults to `r4pfWXtMiS`

---

## Verification Test Cases

The test script automatically verifies the following 6 core scenarios:

1. **Unauthenticated Dashboard Redirect (`/?redirect=...`)**:
   - Accessing `/{secret}/dashboard/` without a session must redirect to `/{secret}/?redirect=/{secret}/dashboard/`.
   - Security disguise gateway (`#gw-login-gate`) must be immediately visible.
   - React root (`#root`) must be hidden to prevent white screen or unauthenticated dashboard flicker.
   - Title must display `安全访问网关 · Security Gateway` without exposing panel branding.
   - No JavaScript console syntax errors.

2. **Form Elements & Disguise Branding Integrity**:
   - Form fields (`#gw-username`, `#gw-password`, `#gw-submit-btn`) must be present and interactable.
   - DOM must not leak legacy branding classes such as `nz-force-auth` (must use generic `gw-force-auth`).

3. **Login Submission & Forwarding**:
   - Submitting valid credentials must authenticate via `/api/v1/login`.
   - The browser must automatically forward to the original destination (`/{secret}/dashboard/`) smoothly.

4. **Dashboard Stability & Anti-Bounce**:
   - Accessing `/{secret}/dashboard/` directly after login must remain on the dashboard.
   - No infinite bounce loop between `/dashboard/` and `/?redirect=`.
   - React dashboard `#root` must contain rendered child nodes (no blank white screen).

5. **Public Monitor & User Status Pill**:
   - Accessing the public view `/{secret}/` with an active session must display `#gw-auth-pill`.
   - User pill must provide quick entry to dashboard and logout button.
   - Login gate must remain hidden when authenticated.

6. **Logout Integration**:
   - Clicking logout button on `#gw-auth-pill` must clear tokens and session cookies.
   - Security login gate must immediately re-appear.

---

## Artifacts & Screenshots

Screenshots for each stage are captured in:
`/home/ubuntu/playwright_verification/latest/`
- `01_unauth_gate.png`: Login gate appearance on unauthenticated redirect.
- `02_filled_credentials.png`: Credentials populated in disguise form.
- `03_dashboard_authenticated.png`: Forwarded dashboard after login.
- `04_dashboard_stable.png`: Direct dashboard access stability.
- `05_front_authenticated.png`: Public monitor with user pill.
- `06_after_logout.png`: Restored login gate after logout.

---

## Troubleshooting & Browser Setup

On ARM64 Linux VM:
- Browser cache is located at `/home/ubuntu/.cache/ms-playwright/firefox-1543/`.
- If browser binary is missing, extract `/tmp/firefox.zip` into `/home/ubuntu/.cache/ms-playwright/firefox-1543/` and run `chmod +x /home/ubuntu/.cache/ms-playwright/firefox-1543/firefox/firefox`.
