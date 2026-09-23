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

		// 3. Unauthenticated request to an internal path -> return 404 to prevent probing!
		c.Header("Content-Type", "text/plain; charset=utf-8")
		c.Header("X-Content-Type-Options", "nosniff")
		c.String(http.StatusNotFound, "404 page not found\n")
		c.Abort()
		return false
	}
}

// isPublicPath checks if the given path and method are publicly accessible.
func isPublicPath(p, method string) bool {
	// Landing page (serves user frontend with custom login gate)
	if p == "/" || p == "" {
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
	if strings.HasPrefix(p, "/api/v1/oauth2/") && method == http.MethodGet {
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
