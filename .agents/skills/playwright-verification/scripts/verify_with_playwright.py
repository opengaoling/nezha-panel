#!/usr/bin/env python3
"""
Playwright End-to-End Automated Verification Script
Verifies:
1. Gating & Redirection: Unauthenticated /dashboard/ bounces to /?redirect=...
2. Security Login Gate: Card renders, input fields exist (#gw-username, #gw-password), no infinite reload.
3. Disguise Integrity: No branding leaks in gate DOM/title.
4. Authentication Flow: Submitting login credentials successfully enters /dashboard/ without bounce.
5. Authenticated State: User pill (#gw-auth-pill) exists, dashboard loads without white screen.
6. Logout Flow: Logout cleanly clears session and returns to login gate.
"""

import os
import sys
import time
from playwright.sync_api import sync_playwright, expect

BASE_URL = os.environ.get("BASE_URL", "http://127.0.0.1:2052")
SECRET = os.environ.get("SECRET", "mKovrigH")
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("ADMIN_PASS", "admin")

SCREENSHOT_DIR = "/home/ubuntu/playwright_verification/latest"
os.makedirs(SCREENSHOT_DIR, exist_ok=True)

PASS = "\033[92m✓ PASS\033[0m"
FAIL = "\033[91m✗ FAIL\033[0m"
INFO = "\033[94mℹ INFO\033[0m"

results = []

def ok(name):
    print(f"  {PASS} {name}")
    results.append((name, True, ""))

def fail(name, reason=""):
    print(f"  {FAIL} {name}: {reason}")
    results.append((name, False, reason))

def run_suite():
    print(f"\n{INFO} Starting Playwright verification on {BASE_URL}/{SECRET}/")
    with sync_playwright() as p:
        try:
            browser = p.firefox.launch(headless=True)
        except Exception as e_firefox:
            try:
                browser = p.chromium.launch(headless=True, args=["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage"])
            except Exception as e_chrome:
                browser = p.webkit.launch(headless=True)
        context = browser.new_context(viewport={"width": 1280, "height": 800})
        page = context.new_page()

        console_errors = []
        def on_console(msg):
            if msg.type == "error":
                text = msg.text
                # Filter benign resource/favicon 404s
                if "favicon" not in text.lower() and "apple-touch-icon" not in text.lower():
                    console_errors.append(text)
        page.on("console", on_console)

        # ---------------------------------------------------------
        # TEST 1: Unauthenticated visit to /dashboard/ redirects to gateway with ?redirect=
        # ---------------------------------------------------------
        print(f"\n[Test 1] Unauthenticated visit to /{SECRET}/dashboard/")
        page.goto(f"{BASE_URL}/{SECRET}/dashboard/", wait_until="networkidle")
        page.wait_for_timeout(1000)

        current_url = page.url
        print(f"  Current URL: {current_url}")
        if "redirect=" in current_url:
            ok("Redirected to gateway with redirect parameter")
        else:
            fail("Expected redirect parameter in URL", current_url)

        # Check if gate is visible
        gate = page.locator("#gw-login-gate, #nz-login-gate").first
        if gate.is_visible():
            ok("Security gateway login gate is visible")
        else:
            fail("Login gate is not visible")

        # Check no syntax errors on page
        syntax_errors = [e for e in console_errors if "SyntaxError" in e or "Unexpected token" in e]
        if not syntax_errors:
            ok("No JavaScript syntax errors during gate execution")
        else:
            fail("JavaScript syntax errors found", str(syntax_errors))

        # Check disguise title
        title = page.title()
        if "安全访问网关" in title or "Security Gateway" in title:
            ok(f"Page title is disguised correctly: '{title}'")
        else:
            fail("Page title leaked or incorrect", title)

        page.screenshot(path=f"{SCREENSHOT_DIR}/01_unauth_gate.png")

        # ---------------------------------------------------------
        # TEST 2: Check Input Form Elements
        # ---------------------------------------------------------
        print(f"\n[Test 2] Form Elements & Branding Integrity")
        user_input = page.locator("#gw-username, #nz-username").first
        pass_input = page.locator("#gw-password, #nz-password").first
        submit_btn = page.locator("#gw-submit-btn, #nz-submit-btn").first

        if user_input.is_visible() and pass_input.is_visible() and submit_btn.is_visible():
            ok("Login credentials input and submit button exist and are visible")
        else:
            fail("Login inputs or submit button missing")

        # Check DOM does not leak nz-force-auth
        has_nz_force = page.evaluate("() => document.documentElement.classList.contains('nz-force-auth')")
        if not has_nz_force:
            ok("DOM root does not contain nz-force-auth class (generic gw- used)")
        else:
            fail("DOM root still contains legacy nz-force-auth class")

        # ---------------------------------------------------------
        # TEST 3: Login Submission & Auto-Forward into /dashboard/
        # ---------------------------------------------------------
        print(f"\n[Test 3] Login Submission and Navigation")
        user_input.fill(ADMIN_USER)
        pass_input.fill(ADMIN_PASS)
        page.screenshot(path=f"{SCREENSHOT_DIR}/02_filled_credentials.png")

        submit_btn.click()
        page.wait_for_timeout(1500)
        page.wait_for_load_state("networkidle")
        page.wait_for_timeout(1500)

        after_login_url = page.url
        print(f"  URL after login: {after_login_url}")
        if "/dashboard" in after_login_url:
            ok("Successfully logged in and navigated into /dashboard/")
        else:
            fail("Did not navigate to /dashboard/ after login", after_login_url)

        page.screenshot(path=f"{SCREENSHOT_DIR}/03_dashboard_authenticated.png")

        # ---------------------------------------------------------
        # TEST 4: Direct Dashboard Access (No Bounce Loop)
        # ---------------------------------------------------------
        print(f"\n[Test 4] Dashboard Session Stability (Anti-Bounce)")
        page.goto(f"{BASE_URL}/{SECRET}/dashboard/", wait_until="networkidle")
        page.wait_for_timeout(1000)

        dash_url = page.url
        if "/dashboard" in dash_url and "redirect=" not in dash_url:
            ok("Dashboard remains stable without bouncing back to login gateway")
        else:
            fail("Bounced back to gateway on direct access", dash_url)

        # Check root is rendered and not blank
        root_children = page.evaluate("() => document.getElementById('root')?.childNodes?.length || 0")
        if root_children > 0:
            ok(f"Dashboard React root mounted with {root_children} child nodes (no white screen)")
        else:
            fail("Dashboard React root is empty")

        page.screenshot(path=f"{SCREENSHOT_DIR}/04_dashboard_stable.png")

        # ---------------------------------------------------------
        # TEST 5: Public View with Session Pill
        # ---------------------------------------------------------
        print(f"\n[Test 5] Front Public View in Authenticated State")
        page.goto(f"{BASE_URL}/{SECRET}/", wait_until="networkidle")
        page.wait_for_timeout(1000)

        pill = page.locator("#gw-auth-pill, #nz-auth-pill").first
        if pill.is_visible():
            ok("Authenticated user pill is visible on public view")
        else:
            fail("Authenticated user pill is not visible")

        gate_on_front = page.locator("#gw-login-gate, #nz-login-gate").first
        if not gate_on_front.is_visible():
            ok("Login gate is correctly hidden when authenticated")
        else:
            fail("Login gate is visible while authenticated")

        page.screenshot(path=f"{SCREENSHOT_DIR}/05_front_authenticated.png")

        # ---------------------------------------------------------
        # TEST 6: Logout Flow
        # ---------------------------------------------------------
        print(f"\n[Test 6] Logout Integration")
        page.on("dialog", lambda dialog: dialog.accept())
        logout_btn = page.locator("#gw-logout-btn, #nz-logout-btn").first
        if logout_btn.is_visible():
            logout_btn.click()
            page.wait_for_timeout(1500)
            page.wait_for_load_state("networkidle")
            
            # After logout, gate should appear
            gate_after = page.locator("#gw-login-gate, #nz-login-gate").first
            if gate_after.is_visible():
                ok("Logged out successfully, security gateway gate restored")
            else:
                fail("Login gate not restored after logout")
        else:
            fail("Logout button not found on user pill")

        page.screenshot(path=f"{SCREENSHOT_DIR}/06_after_logout.png")

        browser.close()

    print("\n" + "="*50)
    print("PLAYWRIGHT VERIFICATION SUMMARY:")
    passed_cnt = sum(1 for _, s, _ in results if s)
    failed_cnt = sum(1 for _, s, _ in results if not s)
    print(f"Total: {len(results)}, Passed: {passed_cnt}, Failed: {failed_cnt}")
    print("="*50)

    if failed_cnt > 0:
        sys.exit(1)
    print("All Playwright verification tests PASSED!\n")

if __name__ == "__main__":
    run_suite()
