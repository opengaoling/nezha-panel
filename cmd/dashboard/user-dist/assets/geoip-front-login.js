/**
 * Nezha Monitoring - Custom Access Gateway Login Controller
 * Exclusive Modern Cyber-Glassmorphic Login UI
 * Handles authentication gating, session verification, login submission,
 * and user dashboard logout integration.
 */
(function () {
  'use strict';

  if (window.__nzLoginGateInstalled) return;
  window.__nzLoginGateInstalled = true;

  var AUTH_COOKIE_NAME = "nz-jwt";
  var CSRF_COOKIE_NAME = "nz-csrf";
  var THEME_STORAGE_KEY = "vite-ui-theme";
  var USER_STORAGE_KEY = "nezha-user-profile";
  var SAVED_USER_KEY = "nezha-saved-username";

  // Helper: Cookie extraction
  function getCookie(name) {
    try {
      var prefix = name + "=";
      var parts = document.cookie ? document.cookie.split(";") : [];
      for (var i = 0; i < parts.length; i++) {
        var part = parts[i].trim();
        if (part.indexOf(prefix) === 0) {
          return decodeURIComponent(part.substring(prefix.length));
        }
      }
    } catch (_e) {}
    return "";
  }

  // Helper: Secret path prefix detection
  function getSecretPrefix() {
    var secretCookie = getCookie("nz-secret-path");
    if (secretCookie) {
      try { localStorage.setItem("nz-secret-path", secretCookie); } catch (_e) {}
      return "/" + encodeURIComponent(secretCookie);
    }
    var parts = window.location.pathname.split("/").filter(Boolean);
    if (parts.length > 0 && /^[a-zA-Z]{8}$/.test(parts[0])) {
      var first = parts[0].toLowerCase();
      if (first !== "settings" && first !== "terminal" && first !== "transfer") {
        try { localStorage.setItem("nz-secret-path", parts[0]); } catch (_e) {}
        return "/" + parts[0];
      }
    }
    try {
      var stored = localStorage.getItem("nz-secret-path");
      if (stored && /^[a-zA-Z]{8}$/.test(stored)) {
        return "/" + stored;
      }
    } catch (_e) {}
    return "";
  }

  // Helper: Clear authentication tokens
  function clearAuthSession() {
    try {
      document.cookie = AUTH_COOKIE_NAME + "=; Max-Age=0; path=/; SameSite=Lax";
      document.cookie = CSRF_COOKIE_NAME + "=; Max-Age=0; path=/; SameSite=Strict";
    } catch (_e) {}
    try {
      localStorage.removeItem("token");
      localStorage.removeItem("nezha-token");
      localStorage.removeItem("jwt");
      localStorage.removeItem(USER_STORAGE_KEY);
      sessionStorage.removeItem("token");
      sessionStorage.removeItem("nezha-token");
      sessionStorage.removeItem("jwt");
    } catch (_e) {}
  }

  // Helper: Detect current theme
  function getCurrentTheme() {
    var root = document.documentElement;
    if (root.classList.contains("dark")) return "dark";
    if (root.classList.contains("light")) return "light";
    try {
      var saved = localStorage.getItem(THEME_STORAGE_KEY);
      if (saved === "dark" || saved === "light") return saved;
    } catch (_e) {}
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  // Helper: Toggle theme
  function toggleTheme() {
    var root = document.documentElement;
    var current = getCurrentTheme();
    var next = current === "dark" ? "light" : "dark";

    root.classList.remove("light", "dark");
    root.classList.add(next);
    root.style.colorScheme = next;
    try {
      localStorage.setItem(THEME_STORAGE_KEY, next);
    } catch (_e) {}

    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) {
      meta.setAttribute("content", next === "dark" ? "hsl(30 15% 8%)" : "hsl(0 0% 98%)");
    }

    updateThemeIcon(next);
  }

  function updateThemeIcon(theme) {
    var btn = document.getElementById("nz-theme-toggle-btn");
    if (!btn) return;
    if (theme === "dark") {
      // Sun icon for dark mode (click to switch to light)
      btn.innerHTML = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41"/></svg>';
      btn.setAttribute("title", "切换至浅色模式");
    } else {
      // Moon icon for light mode (click to switch to dark)
      btn.innerHTML = '<svg viewBox="0 0 24 24"><path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/></svg>';
      btn.setAttribute("title", "切换至深色模式");
    }
  }

  var gateEventsBound = false;
  function bindGateEvents() {
    if (gateEventsBound) return;
    gateEventsBound = true;

    // Bind theme button
    var themeBtn = document.getElementById("nz-theme-toggle-btn");
    if (themeBtn) {
      updateThemeIcon(getCurrentTheme());
      themeBtn.addEventListener("click", toggleTheme);
    }

    // Bind password toggle
    var pwdInput = document.getElementById("nz-password");
    var pwdToggle = document.getElementById("nz-pwd-toggle");
    if (pwdInput && pwdToggle) {
      pwdToggle.addEventListener("click", function () {
        var isPwd = pwdInput.type === "password";
        pwdInput.type = isPwd ? "text" : "password";
        var eyeIcon = document.getElementById("nz-eye-icon");
        if (eyeIcon) {
          eyeIcon.innerHTML = isPwd
            ? '<path d="m15 18-.722-3.25"/><path d="M2 8a10.645 10.645 0 0 0 20 0"/><path d="m20 15-1.726-2.05"/><path d="m4 15 1.726-2.05"/><path d="m9 18 .722-3.25"/>'
            : '<path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/>';
        }
      });
    }

    // Prepopulate saved username if available
    try {
      var savedUser = localStorage.getItem(SAVED_USER_KEY);
      var userField = document.getElementById("nz-username");
      var rememberCheck = document.getElementById("nz-remember-check");
      if (savedUser && userField) {
        userField.value = savedUser;
        if (rememberCheck) rememberCheck.checked = true;
        if (pwdInput) pwdInput.focus();
      } else if (userField) {
        userField.focus();
      }
    } catch (_e) {}

    // Update admin link href with secret prefix if applicable
    var secretPrefix = getSecretPrefix();
    var dashUrl = secretPrefix ? secretPrefix + "/dashboard/" : "/dashboard/";
    var adminLinks = document.querySelectorAll(".nz-admin-link");
    for (var i = 0; i < adminLinks.length; i++) {
      adminLinks[i].setAttribute("href", dashUrl);
    }

    // Bind login form submit
    var form = document.getElementById("nz-login-form");
    if (form) {
      form.addEventListener("submit", handleLoginSubmit);
    }
  }

  // Render Login Gate Template into DOM
  function ensureLoginGateDOM() {
    var existing = document.getElementById("nz-login-gate");
    if (existing) {
      existing.style.display = "";
      existing.style.opacity = "1";
      existing.style.pointerEvents = "auto";
      bindGateEvents();
      return existing;
    }

    var container = document.createElement("div");
    container.id = "nz-login-gate";
    container.innerHTML = [
      '<div class="nz-bg-decor">',
      '  <div class="nz-bg-grid"></div>',
      '  <div class="nz-glow-orb nz-glow-orb-1"></div>',
      '  <div class="nz-glow-orb nz-glow-orb-2"></div>',
      '  <div class="nz-glow-orb nz-glow-orb-3"></div>',
      '</div>',
      '<div class="nz-top-bar">',
      '  <button type="button" class="nz-theme-btn" id="nz-theme-toggle-btn" aria-label="Toggle Theme">',
      '  </button>',
      '</div>',
      '<div class="nz-login-card" id="nz-login-card">',
      '  <div class="nz-card-header">',
      '    <div class="nz-logo-wrapper">',
      '      <div class="nz-logo-pulse"></div>',
      '      <div class="nz-logo-box">',
      '        <svg viewBox="0 0 24 24" fill="none" stroke="url(#nz-logo-grad)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">',
      '          <defs>',
      '            <linearGradient id="nz-logo-grad" x1="0%" y1="0%" x2="100%" y2="100%">',
      '              <stop offset="0%" stop-color="#38bdf8" />',
      '              <stop offset="50%" stop-color="#818cf8" />',
      '              <stop offset="100%" stop-color="#c084fc" />',
      '            </linearGradient>',
      '          </defs>',
      '          <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"></polygon>',
      '        </svg>',
      '      </div>',
      '    </div>',
      '    <h1 class="nz-brand-title">哪吒监控</h1>',
      '    <div class="nz-brand-subtitle">NEZHA DASHBOARD · 访问网关</div>',
      '    <div class="nz-gateway-badge">',
      '      <span class="nz-pulse-dot"></span>',
      '      <span>身份认证网关已就绪</span>',
      '    </div>',
      '  </div>',
      '  <div class="nz-alert nz-alert-error" id="nz-alert-error">',
      '    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>',
      '    <span id="nz-error-text">用户名或密码错误</span>',
      '  </div>',
      '  <div class="nz-alert nz-alert-success" id="nz-alert-success">',
      '    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>',
      '    <span id="nz-success-text">验证成功，正在进入系统...</span>',
      '  </div>',
      '  <form class="nz-form" id="nz-login-form" autocomplete="on">',
      '    <div class="nz-field-group">',
      '      <label class="nz-label" for="nz-username">用户名 / 账号</label>',
      '      <div class="nz-input-wrap">',
      '        <div class="nz-input-icon">',
      '          <svg viewBox="0 0 24 24"><path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>',
      '        </div>',
      '        <input type="text" id="nz-username" class="nz-input" placeholder="请输入面板账号" required autocomplete="username" spellcheck="false" />',
      '      </div>',
      '    </div>',
      '    <div class="nz-field-group">',
      '      <label class="nz-label" for="nz-password">访问密码</label>',
      '      <div class="nz-input-wrap">',
      '        <div class="nz-input-icon">',
      '          <svg viewBox="0 0 24 24"><rect width="18" height="11" x="3" y="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>',
      '        </div>',
      '        <input type="password" id="nz-password" class="nz-input" placeholder="请输入面板密码" required autocomplete="current-password" />',
      '        <button type="button" class="nz-pwd-toggle" id="nz-pwd-toggle" aria-label="Toggle Password Visibility">',
      '          <svg id="nz-eye-icon" viewBox="0 0 24 24"><path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/></svg>',
      '        </button>',
      '      </div>',
      '    </div>',
      '    <div class="nz-form-options">',
      '      <label class="nz-remember-label">',
      '        <input type="checkbox" id="nz-remember-check" class="nz-remember-checkbox" />',
      '        <span>记住账号</span>',
      '      </label>',
      '      <a href="/dashboard/" class="nz-admin-link">',
      '        <span>管理后台</span>',
      '        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M5 12h14M12 5l7 7-7 7"/></svg>',
      '      </a>',
      '    </div>',
      '    <button type="submit" class="nz-submit-btn" id="nz-submit-btn">',
      '      <span class="nz-spinner"></span>',
      '      <span class="nz-btn-text">登 录 进 入</span>',
      '    </button>',
      '  </form>',
      '  <div class="nz-card-footer">',
      '    <div>哪吒监控系统 · 安全身份认证网关</div>',
      '    <div style="opacity: 0.6; margin-top: 2px;">End-to-End Encrypted Session</div>',
      '  </div>',
      '</div>'
    ].join("\n");

    var target = document.body || document.documentElement;
    if (target) {
      target.appendChild(container);
      bindGateEvents();
    }
    return container;
  }

  // Handle Form Submission
  function handleLoginSubmit(event) {
    if (event) event.preventDefault();

    var userInput = document.getElementById("nz-username");
    var pwdInput = document.getElementById("nz-password");
    var submitBtn = document.getElementById("nz-submit-btn");
    var card = document.getElementById("nz-login-card");
    var errAlert = document.getElementById("nz-alert-error");
    var errText = document.getElementById("nz-error-text");
    var succAlert = document.getElementById("nz-alert-success");
    var rememberCheck = document.getElementById("nz-remember-check");

    if (!userInput || !pwdInput || !submitBtn) return;

    var username = userInput.value.trim();
    var password = pwdInput.value;

    if (!username || !password) {
      showError("请输入完整的用户名和密码");
      return;
    }

    // Set loading state
    submitBtn.classList.add("nz-loading");
    submitBtn.disabled = true;
    if (errAlert) errAlert.classList.remove("nz-show");
    if (succAlert) succAlert.classList.remove("nz-show");

    function showError(msg) {
      submitBtn.classList.remove("nz-loading");
      submitBtn.disabled = false;
      if (errText) errText.textContent = msg || "用户名或密码错误";
      if (errAlert) errAlert.classList.add("nz-show");
      if (card) {
        card.classList.remove("nz-shake");
        void card.offsetWidth; // trigger reflow
        card.classList.add("nz-shake");
      }
      pwdInput.focus();
      pwdInput.select();
    }

    // Save or clear username based on Remember checkbox
    try {
      if (rememberCheck && rememberCheck.checked) {
        localStorage.setItem(SAVED_USER_KEY, username);
      } else {
        localStorage.removeItem(SAVED_USER_KEY);
      }
    } catch (_e) {}

    // POST /api/v1/login (Panel Native Auth API)
    fetch("/api/v1/login", {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      credentials: "same-origin",
      body: JSON.stringify({
        username: username,
        password: password
      })
    })
      .then(function (res) {
        return res.json().then(function (data) {
          return { ok: res.ok, status: res.status, data: data };
        });
      })
      .then(function (result) {
        if (!result.ok || !result.data || !result.data.success) {
          var errorMsg = "用户名或密码错误";
          if (result.data && result.data.error) {
            errorMsg = result.data.error;
          }
          showError(errorMsg);
          return;
        }

        // Login Success!
        var token = result.data.data && result.data.data.token;
        if (token) {
          try {
            localStorage.setItem("token", token);
            localStorage.setItem("nezha-token", token);
            localStorage.setItem("jwt", token);
          } catch (_e) {}
        }

        try {
          localStorage.setItem(USER_STORAGE_KEY, JSON.stringify({ username: username }));
        } catch (_e) {}

        if (succAlert) succAlert.classList.add("nz-show");

        // Unlock gate with smooth transition
        setTimeout(function () {
          unlockGateAndEnter();
        }, 500);
      })
      .catch(function (err) {
        showError("登录网络错误: " + (err.message || "请求失败"));
      });
  }

  // Unlock gate and reveal dashboard
  function unlockGateAndEnter() {
    document.documentElement.classList.add("nz-authenticated");
    var gate = document.getElementById("nz-login-gate");
    if (gate) {
      gate.style.opacity = "0";
      gate.style.pointerEvents = "none";
      setTimeout(function () {
        if (gate.parentNode) gate.parentNode.removeChild(gate);
      }, 400);
    }
    try {
      var params = new URLSearchParams(window.location.search);
      var target = params.get("redirect");
      if (target && target.startsWith("/")) {
        window.location.href = target;
        return;
      }
    } catch (_e) {}
    // Reload cleanly to initialize React TanStack Query & WebSocket with session cookies
    window.location.reload();
  }

  // Mount Dashboard User Status Pill & Logout Button
  function mountDashboardUserPill(username) {
    if (document.getElementById("nz-auth-pill")) return;

    function renderPill() {
      if (document.getElementById("nz-auth-pill")) return;
      var target = document.body || document.documentElement;
      if (!target) return;

      var prefix = getSecretPrefix();
      var dashUrl = prefix ? prefix + "/dashboard/" : "/dashboard/";

      var pill = document.createElement("div");
      pill.id = "nz-auth-pill";

      var displayName = username || "管理员";
      var avatarLetter = displayName.charAt(0).toUpperCase();

      pill.innerHTML = [
        '<div class="nz-pill-avatar">' + avatarLetter + '</div>',
        '<span class="nz-pill-user" title="' + displayName + '">' + displayName + '</span>',
        '<div class="nz-pill-actions">',
        '  <a href="' + dashUrl + '" class="nz-pill-btn" title="进入管理后台">',
        '    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/></svg>',
        '    <span>后台</span>',
        '  </a>',
        '  <button type="button" class="nz-pill-btn nz-pill-logout" id="nz-logout-btn" title="退出登录">',
        '    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/></svg>',
        '    <span>退出</span>',
        '  </button>',
        '</div>'
      ].join("");

      target.appendChild(pill);

      var adminLinks = document.querySelectorAll(".nz-admin-link");
      for (var i = 0; i < adminLinks.length; i++) {
        adminLinks[i].setAttribute("href", dashUrl);
      }

      var logoutBtn = document.getElementById("nz-logout-btn");
      if (logoutBtn) {
        logoutBtn.addEventListener("click", function () {
          if (window.confirm("确定要退出登录吗？")) {
            clearAuthSession();
            document.documentElement.classList.remove("nz-authenticated");
            window.location.reload();
          }
        });
      }
    }

    if (document.body) {
      renderPill();
    } else {
      document.addEventListener("DOMContentLoaded", renderPill, { once: true });
    }
  }

  // Verify Session with Backend
  function verifySession() {
    var hasCookie = !!getCookie(AUTH_COOKIE_NAME);
    var storageToken = "";
    try {
      storageToken = localStorage.getItem("token") || localStorage.getItem("nezha-token") || localStorage.getItem("jwt") || "";
    } catch (_e) {}
    var hasStorageToken = !!storageToken;

    var isExplicitLogin = window.location.pathname.indexOf("/login") !== -1 ||
      (new URLSearchParams(window.location.search)).has("login") ||
      (new URLSearchParams(window.location.search)).has("redirect") ||
      window.__forceAuthGate === true;

    // If no credentials exist anywhere, definitely not logged in
    if (!hasCookie && !hasStorageToken) {
      document.documentElement.classList.remove("nz-authenticated");
      if (isExplicitLogin) {
        document.documentElement.classList.add("nz-force-auth");
        ensureLoginGateDOM();
      }
      return;
    }

    var headers = {};
    if (storageToken) {
      headers["Authorization"] = "Bearer " + storageToken;
    }

    // Verify session by calling /api/v1/profile
    fetch("/api/v1/profile", {
      method: "GET",
      headers: headers,
      credentials: "same-origin"
    })
      .then(function (res) {
        if (res.ok) {
          return res.json();
        }
        throw new Error("Unauthorized");
      })
      .then(function (profileRes) {
        if (profileRes && profileRes.success) {
          // If there was a redirect URL waiting, navigate there now
          try {
            var params = new URLSearchParams(window.location.search);
            var target = params.get("redirect");
            if (target && target.startsWith("/")) {
              window.location.replace(target);
              return;
            }
          } catch (_e) {}

          // Session is fully verified & active!
          document.documentElement.classList.add("nz-authenticated");
          document.documentElement.classList.remove("nz-force-auth");
          var gate = document.getElementById("nz-login-gate");
          if (gate && gate.parentNode) {
            gate.parentNode.removeChild(gate);
          }
          var uname = (profileRes.data && profileRes.data.username) || "管理员";
          mountDashboardUserPill(uname);
        } else {
          throw new Error("Invalid profile response");
        }
      })
      .catch(function () {
        // Session invalid or expired: clear and show login gate only if explicit login
        clearAuthSession();
        document.documentElement.classList.remove("nz-authenticated");
        if (isExplicitLogin) {
          document.documentElement.classList.add("nz-force-auth");
          ensureLoginGateDOM();
        }
      });
  }

  // Hook into auth guard events for automatic logout on 401
  window.addEventListener("nz:auth-required", function () {
    clearAuthSession();
    document.documentElement.classList.remove("nz-authenticated");
    ensureLoginGateDOM();
  });

  function initGate() {
    bindGateEvents();
    verifySession();
  }

  // Execute verification as soon as DOM is ready or immediately
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initGate);
  } else {
    initGate();
  }

})();
