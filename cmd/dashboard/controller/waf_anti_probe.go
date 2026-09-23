package controller

import (
	"net/http"
	"strings"
	"time"

	jwt "github.com/appleboy/gin-jwt/v2"
	"github.com/gin-gonic/gin"
	"github.com/goccy/go-json"

	"github.com/nezhahq/nezha/cmd/dashboard/controller/waf"
	"github.com/nezhahq/nezha/model"
	"github.com/nezhahq/nezha/service/singleton"
)

const (
	SecretPathCookieName = "nz-secret-path"
	SecretPathHeaderName = "X-Secret-Path"
)

// secretPathHandler wraps the inner HTTP handler to enforce the random
// secret path prefix requirement. Any request that lacks the secret path prefix
// (and lacks an authenticated secret cookie/header/PAT) returns 404 to prevent probing.
func secretPathHandler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		secret := ""
		if singleton.Conf != nil {
			secret = strings.Trim(singleton.Conf.SecretPath, "/")
		}

		// When SecretPath is empty/not configured, bypass
		if secret == "" {
			next.ServeHTTP(w, r)
			return
		}

		reqPath := r.URL.Path
		secretPrefix := "/" + secret

		// 1. Check path prefix: /{secret} or /{secret}/*
		hasPathSecret := reqPath == secretPrefix || strings.HasPrefix(reqPath, secretPrefix+"/")

		// 2. Query param ?secret={secret}
		hasQuerySecret := r.URL.Query().Get("secret") == secret

		// 3. API PAT token in Authorization header
		hasPAT := false
		rawAuth := strings.TrimSpace(r.Header.Get("Authorization"))
		if strings.HasPrefix(rawAuth, "Bearer nzp_") {
			hasPAT = true
		}

		// 4. Check secret cookie or header
		hasCookieSecret := false
		if cookie, err := r.Cookie(SecretPathCookieName); err == nil && cookie.Value == secret {
			hasCookieSecret = true
		}
		hasHeaderSecret := r.Header.Get(SecretPathHeaderName) == secret

		// If accessed via URL path or query secret, set/refresh the secret cookie
		if hasPathSecret || hasQuerySecret {
			http.SetCookie(w, &http.Cookie{
				Name:     SecretPathCookieName,
				Value:    secret,
				Path:     "/",
				MaxAge:   30 * 86400,
				SameSite: http.SameSiteLaxMode,
			})
			r.Header.Set(SecretPathHeaderName, secret)
		}

		// Handle exact secret prefix /{secret} -> redirect to /{secret}/
		if reqPath == secretPrefix {
			target := secretPrefix + "/"
			if r.URL.RawQuery != "" {
				target += "?" + r.URL.RawQuery
			}
			http.Redirect(w, r, target, http.StatusMovedPermanently)
			return
		}

		// If accessed with secret path prefix:
		if hasPathSecret {
			sub := strings.TrimPrefix(reqPath, secretPrefix)

			// Support domain.com/{secret}/Dashboard and domain.com/{secret}/dashboard
			if strings.EqualFold(sub, "/dashboard") || strings.EqualFold(sub, "/admin") {
				target := secretPrefix + "/dashboard/"
				if r.URL.RawQuery != "" {
					target += "?" + r.URL.RawQuery
				}
				http.Redirect(w, r, target, http.StatusMovedPermanently)
				return
			}

			// Normalization: /Dashboard/ -> /dashboard/
			if strings.EqualFold(sub, "/dashboard/") || strings.EqualFold(sub, "/admin/") {
				r.URL.Path = "/dashboard/"
			} else if len(sub) > len("/dashboard/") && strings.EqualFold(sub[:len("/dashboard/")], "/dashboard/") {
				r.URL.Path = "/dashboard/" + sub[len("/dashboard/"):]
			} else {
				r.URL.Path = sub
			}

			next.ServeHTTP(w, r)
			return
		}

		// If accessed via query param ?secret={secret}:
		if hasQuerySecret {
			target := secretPrefix + reqPath
			if strings.EqualFold(reqPath, "/dashboard") || strings.EqualFold(reqPath, "/admin") {
				target = secretPrefix + "/dashboard/"
			}
			http.Redirect(w, r, target, http.StatusMovedPermanently)
			return
		}

		// For requests without the secret path in the URL:
		// Subresources (/assets/*, /dashboard/assets/*, static icons) and /api/*
		// are allowed if authorized by cookie/header/PAT, or if completing an OAuth2 callback.
		if (hasCookieSecret || hasHeaderSecret || hasPAT || strings.HasPrefix(reqPath, "/api/v1/oauth2/callback")) && isSubresourceOrApi(reqPath) {
			next.ServeHTTP(w, r)
			return
		}

		// All other requests without secret in URL (e.g. naked port "/", "/dashboard", "/login",
		// or any unauthenticated probes) must promptly return 404!
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte("404 page not found\n"))
	})
}

// isSubresourceOrApi checks if the path is an asset, static icon, or API request
// that is loaded by the frontend pages rather than a top-level page document route.
func isSubresourceOrApi(p string) bool {
	if strings.HasPrefix(p, "/assets/") || strings.HasPrefix(p, "/dashboard/assets/") || strings.HasPrefix(p, "/api/") {
		return true
	}
	switch p {
	case "/favicon.ico", "/manifest.json", "/robots.txt",
		"/android-chrome-192x192.png", "/android-chrome-512x512.png",
		"/apple-touch-icon.png", "/animated-man.webp", "/logo.svg",
		"/dashboard/logo.svg":
		return true
	}
	return false
}

// initAntiProbeWAF registers the anti-probe guard into the front WAF.
// If an unauthenticated client attempts to access any internal path
// (such as /dashboard, /dashboard/*, protected /api/v1/*, /mcp, /swagger, /debug, etc.),
// the server responds with a standard 404 Not Found to prevent probing and fingerprinting.
func initAntiProbeWAF(mw *jwt.GinJWTMiddleware) {
	waf.AntiProbeGuard = func(c *gin.Context) bool {
		path := c.Request.URL.Path

		// 1. Allow public paths without authentication
		if isPublicPath(path, c.Request.Method) {
			return true
		}

		// 2. Internal paths require authentication
		if isClientAuthenticated(c, mw) {
			return true
		}

		// 3. If client has valid secret cookie/header, allow admin dashboard, public APIs, and static assets
		secret := ""
		if singleton.Conf != nil {
			secret = strings.Trim(singleton.Conf.SecretPath, "/")
		}
		if secret != "" {
			cookie, err := c.Cookie(SecretPathCookieName)
			hasSecret := (err == nil && cookie == secret) || c.GetHeader(SecretPathHeaderName) == secret
			if hasSecret {
				// Allow public frontend APIs, settings, profile check, and server stream for legitimate secret path visitors
				if path == "/api/v1/setting" || path == "/api/v1/ws/server" || path == "/api/v1/server-group" ||
					path == "/api/v1/service" || path == "/api/v1/profile" || strings.HasPrefix(path, "/api/v1/service/") ||
					path == "/api/v1/server" || strings.HasPrefix(path, "/api/v1/server/") ||
					path == "/server" || strings.HasPrefix(path, "/server/") {
					return true
				}
				if strings.HasPrefix(path, "/dashboard") {
					return true
				}
			}
		}

		// 4. Unauthenticated request to an internal path -> return 404 to prevent probing!
		c.Header("Content-Type", "text/plain; charset=utf-8")
		c.Header("X-Content-Type-Options", "nosniff")
		c.String(http.StatusNotFound, "404 page not found\n")
		c.Abort()
		return false
	}
}

// isPublicPath checks if the given path and method are publicly accessible.
func isPublicPath(p, method string) bool {
	// Landing page and login page (serves user frontend with custom login gate)
	if p == "/" || p == "" || p == "/login" || p == "/login/" {
		return true
	}

	// Static assets of the public user frontend (/assets/*)
	// Note: /dashboard/assets/* starts with /dashboard/ and is considered internal.
	if strings.HasPrefix(p, "/assets/") {
		return true
	}

	// Root-level static resources needed by browsers for the public frontend
	switch p {
	case "/favicon.ico", "/manifest.json", "/robots.txt",
		"/android-chrome-192x192.png", "/android-chrome-512x512.png",
		"/apple-touch-icon.png", "/animated-man.webp", "/logo.svg":
		return true
	}

	// Public login submission API
	if p == "/api/v1/login" && method == http.MethodPost {
		return true
	}

	// Public OAuth2 initiation and callback (GET only)
	if strings.HasPrefix(p, "/api/v1/oauth2") && method == http.MethodGet {
		return true
	}

	return false
}

// isClientAuthenticated checks if the request has a valid PAT or JWT session.
func isClientAuthenticated(c *gin.Context, mw *jwt.GinJWTMiddleware) bool {
	// Fast path: already authenticated in context
	if auth, exists := c.Get(model.CtxKeyAuthorizedUser); exists && auth != nil {
		return true
	}

	rawAuth := strings.TrimSpace(c.GetHeader("Authorization"))

	// Check PAT (Personal Access Token): Authorization: Bearer nzp_*
	if strings.HasPrefix(rawAuth, "Bearer nzp_") {
		plaintext := strings.TrimSpace(strings.TrimPrefix(rawAuth, "Bearer "))
		if strings.HasPrefix(plaintext, model.APITokenPrefix) {
			var tok model.APIToken
			if err := singleton.DB.Where("token_hash = ?", model.HashAPIToken(plaintext)).First(&tok).Error; err == nil {
				if !tok.IsExpired(time.Now()) {
					var user model.User
					if err := singleton.DB.First(&user, tok.UserID).Error; err == nil {
						c.Set(model.CtxKeyAuthorizedUser, &user)
						c.Set(model.CtxKeyAPIToken, &tok)
						return true
					}
				}
			}
		}
		return false
	}

	// Fast path: check if any JWT credentials (cookie, Bearer, query) are present
	hasCookie := false
	if cookie, err := c.Cookie("nz-jwt"); err == nil && strings.TrimSpace(cookie) != "" {
		hasCookie = true
	}
	hasHeader := strings.HasPrefix(rawAuth, "Bearer ")
	hasQuery := strings.TrimSpace(c.Query("token")) != ""

	if !hasCookie && !hasHeader && !hasQuery {
		return false
	}

	if mw == nil {
		return false
	}

	claims, err := mw.GetClaimsFromJWT(c)
	if err != nil || claims == nil {
		return false
	}

	// Check expiration
	expValid := false
	switch v := claims["exp"].(type) {
	case float64:
		expValid = int64(v) >= mw.TimeFunc().Unix()
	case json.Number:
		if n, err := v.Int64(); err == nil {
			expValid = n >= mw.TimeFunc().Unix()
		}
	}
	if !expValid {
		return false
	}

	// Verify session in DB
	keyID, ok := claims[jwtClaimKeyID].(string)
	if !ok || keyID == "" {
		return false
	}
	encodedUID, ok := claims[jwtClaimUserID].(string)
	if !ok || encodedUID == "" {
		return false
	}

	var sess model.JWTSession
	if err := singleton.DB.Where("key_id = ?", keyID).First(&sess).Error; err != nil {
		return false
	}
	if sess.RevokedAt != nil || time.Now().After(sess.ExpiresAt) {
		return false
	}

	var user model.User
	if err := singleton.DB.First(&user, sess.UserID).Error; err != nil {
		return false
	}
	if user.TokenVersion != sess.TokenVersion {
		return false
	}

	// Cache user and session in context for downstream handlers
	c.Set(model.CtxKeyAuthorizedUser, &user)
	c.Set(jwtClaimKeyID, keyID)
	c.Set("JWT_PAYLOAD", claims)
	return true
}
