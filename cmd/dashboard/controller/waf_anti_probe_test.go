package controller

import (
	"net/http"
	"net/http/httptest"
	"regexp"
	"testing"
	"time"

	jwt "github.com/appleboy/gin-jwt/v2"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"github.com/nezhahq/nezha/cmd/dashboard/controller/waf"
	"github.com/nezhahq/nezha/model"
	"github.com/nezhahq/nezha/pkg/idcodec"
	"github.com/nezhahq/nezha/pkg/utils"
	"github.com/nezhahq/nezha/service/singleton"
)

func setupAntiProbeWAFTest(t *testing.T) (*gin.Engine, *jwt.GinJWTMiddleware, func()) {
	t.Helper()
	gin.SetMode(gin.TestMode)

	masterKey := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	require.NoError(t, idcodec.Init([]byte(masterKey)))

	originalDB := singleton.DB
	originalConf := singleton.Conf
	origGuard := waf.AntiProbeGuard

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&model.User{}, &model.JWTSession{}, &model.WAF{}, &model.APIToken{}))
	singleton.DB = db
	singleton.Conf = &singleton.ConfigClass{Config: &model.Config{
		JWTTimeout:   1,
		JWTSecretKey: masterKey,
		ConfigDashboard: model.ConfigDashboard{
			AdminTemplate: "admin-dist",
			UserTemplate:  "user-dist",
		},
	}}

	r := gin.New()
	r.RedirectTrailingSlash = false
	r.Use(waf.Waf)

	authMw, err := jwt.New(initParams())
	require.NoError(t, err)
	require.NoError(t, authMw.MiddlewareInit())

	initAntiProbeWAF(authMw)

	// Mock routes
	r.GET("/", func(c *gin.Context) { c.String(http.StatusOK, "welcome") })
	r.GET("/assets/app.js", func(c *gin.Context) { c.String(http.StatusOK, "app.js") })
	r.GET("/favicon.ico", func(c *gin.Context) { c.String(http.StatusOK, "favicon") })
	r.POST("/api/v1/login", func(c *gin.Context) { c.String(http.StatusOK, "login-ok") })
	r.GET("/dashboard/", func(c *gin.Context) { c.String(http.StatusOK, "dashboard-ok") })
	r.GET("/dashboard/login", func(c *gin.Context) { c.String(http.StatusOK, "dashboard-login-ok") })
	r.GET("/dashboard/service", func(c *gin.Context) { c.String(http.StatusOK, "dashboard-service-ok") })
	r.GET("/dashboard/service/", func(c *gin.Context) { c.String(http.StatusOK, "dashboard-service-ok") })
	r.GET("/api/v1/oauth2/callback", func(c *gin.Context) { c.String(http.StatusOK, "oauth2-callback-ok") })
	r.GET("/api/v1/profile", func(c *gin.Context) { c.String(http.StatusOK, "profile-ok") })
	r.GET("/api/v1/server", func(c *gin.Context) { c.String(http.StatusOK, "server-ok") })
	r.POST("/mcp", func(c *gin.Context) { c.String(http.StatusOK, "mcp-ok") })
	r.NoRoute(func(c *gin.Context) { c.String(http.StatusNotFound, "404 page not found\n") })

	cleanup := func() {
		singleton.DB = originalDB
		singleton.Conf = originalConf
		waf.AntiProbeGuard = origGuard
	}

	return r, authMw, cleanup
}

func TestAntiProbeWAFUnauthenticatedProbesReturn404(t *testing.T) {
	r, _, cleanup := setupAntiProbeWAFTest(t)
	defer cleanup()

	// Probes on internal paths MUST return 404
	internalTargets := []struct {
		method string
		path   string
	}{
		{"GET", "/dashboard"},
		{"GET", "/dashboard/"},
		{"GET", "/dashboard/login"},
		{"GET", "/dashboard/settings"},
		{"GET", "/dashboard/assets/app.js"},
		{"GET", "/api/v1/profile"},
		{"GET", "/api/v1/server"},
		{"GET", "/api/v1/setting"},
		{"POST", "/mcp"},
		{"GET", "/mcp"},
		{"GET", "/swagger/index.html"},
		{"GET", "/debug/pprof"},
		{"GET", "/server"},
		{"GET", "/server/1"},
		{"GET", "/random-probe"},
		{"GET", "/api/v1/login"}, // GET /login should not be allowed
	}

	for _, tt := range internalTargets {
		t.Run(tt.method+" "+tt.path, func(t *testing.T) {
			req := httptest.NewRequest(tt.method, tt.path, nil)
			w := httptest.NewRecorder()
			r.ServeHTTP(w, req)

			assert.Equal(t, http.StatusNotFound, w.Code, "internal path %s must return 404 for unauthenticated requests", tt.path)
			assert.Contains(t, w.Body.String(), "404 page not found")
		})
	}
}

func TestAntiProbeWAFPublicPathsAllowed(t *testing.T) {
	r, _, cleanup := setupAntiProbeWAFTest(t)
	defer cleanup()

	publicTargets := []struct {
		method       string
		path         string
		expectedCode int
	}{
		{"GET", "/", http.StatusOK},
		{"GET", "/assets/app.js", http.StatusOK},
		{"GET", "/favicon.ico", http.StatusOK},
		{"POST", "/api/v1/login", http.StatusOK},
	}

	for _, tt := range publicTargets {
		t.Run(tt.method+" "+tt.path, func(t *testing.T) {
			req := httptest.NewRequest(tt.method, tt.path, nil)
			w := httptest.NewRecorder()
			r.ServeHTTP(w, req)

			assert.Equal(t, tt.expectedCode, w.Code, "public path %s must be accessible", tt.path)
		})
	}
}

func TestAntiProbeWAFAuthenticatedAccessAllowed(t *testing.T) {
	r, authMw, cleanup := setupAntiProbeWAFTest(t)
	defer cleanup()

	// Create test user and session
	user := model.User{
		Common:       model.Common{ID: 1},
		Username:     "admin",
		TokenVersion: 1,
	}
	require.NoError(t, singleton.DB.Create(&user).Error)

	sessData, err := issueJWTSession(&gin.Context{Request: httptest.NewRequest("GET", "/", nil)}, &user, 1)
	require.NoError(t, err)

	token, _, err := authMw.TokenGenerator(sessData)
	require.NoError(t, err)

	// Authenticated request with cookie to /dashboard/
	req := httptest.NewRequest("GET", "/dashboard/", nil)
	req.AddCookie(&http.Cookie{Name: "nz-jwt", Value: token})
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	assert.Equal(t, http.StatusOK, w.Code)
	assert.Equal(t, "dashboard-ok", w.Body.String())

	// Authenticated request with cookie to /api/v1/profile
	reqProfile := httptest.NewRequest("GET", "/api/v1/profile", nil)
	reqProfile.AddCookie(&http.Cookie{Name: "nz-jwt", Value: token})
	wProfile := httptest.NewRecorder()
	r.ServeHTTP(wProfile, reqProfile)
	assert.Equal(t, http.StatusOK, wProfile.Code)
	assert.Equal(t, "profile-ok", wProfile.Body.String())

	// Authenticated request with PAT
	patPlaintext := "nzp_testtoken1234567890abcdef"
	exp := time.Now().Add(time.Hour)
	tok := model.APIToken{
		ID:        10,
		UserID:    user.ID,
		Name:      "ci-pat",
		TokenHash: model.HashAPIToken(patPlaintext),
		ExpiresAt: &exp,
	}
	require.NoError(t, singleton.DB.Create(&tok).Error)

	reqPAT := httptest.NewRequest("GET", "/api/v1/server", nil)
	reqPAT.Header.Set("Authorization", "Bearer "+patPlaintext)
	wPAT := httptest.NewRecorder()
	r.ServeHTTP(wPAT, reqPAT)
	assert.Equal(t, http.StatusOK, wPAT.Code)
	assert.Equal(t, "server-ok", wPAT.Body.String())
}

func TestSecretPathRandomLetterGeneration(t *testing.T) {
	letterRegex := regexp.MustCompile(`^[a-zA-Z]{8}$`)
	for i := 0; i < 50; i++ {
		gen, err := utils.GenerateRandomLetterString(8)
		require.NoError(t, err)
		assert.Len(t, gen, 8)
		assert.True(t, letterRegex.MatchString(gen), "generated string %s must contain only uppercase and lowercase English letters", gen)
	}
}

func TestSecretPathProtectionAndRouting(t *testing.T) {
	r, authMw, cleanup := setupAntiProbeWAFTest(t)
	defer cleanup()

	const secret = "jjjjjjxf"
	singleton.Conf.SecretPath = secret

	handler := secretPathHandler(r)

	// Create test user and auth token for testing authenticated requests
	user := model.User{
		Common:       model.Common{ID: 2},
		Username:     "admin2",
		TokenVersion: 1,
	}
	require.NoError(t, singleton.DB.Create(&user).Error)

	sessData, err := issueJWTSession(&gin.Context{Request: httptest.NewRequest("GET", "/", nil)}, &user, 1)
	require.NoError(t, err)

	token, _, err := authMw.TokenGenerator(sessData)
	require.NoError(t, err)

	patPlaintext := "nzp_secretpat1234567890abcdef"
	exp2 := time.Now().Add(time.Hour)
	tok := model.APIToken{
		ID:        20,
		UserID:    user.ID,
		Name:      "ci-secret-pat",
		TokenHash: model.HashAPIToken(patPlaintext),
		ExpiresAt: &exp2,
	}
	require.NoError(t, singleton.DB.Create(&tok).Error)

	// 1. Probing without secret path / cookie / PAT MUST return 404
	unauthProbes := []string{
		"/",
		"/dashboard",
		"/Dashboard",
		"/dashboard/",
		"/api/v1/profile",
		"/api/v1/login",
		"/assets/app.js",
		"/favicon.ico",
	}
	for _, p := range unauthProbes {
		req := httptest.NewRequest("GET", p, nil)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		assert.Equal(t, http.StatusNotFound, w.Code, "unauthenticated probe to %s must return 404", p)
		assert.Contains(t, w.Body.String(), "404 page not found")
	}

	// 2. Wrong secret path prefix MUST return 404
	wrongProbes := []string{
		"/wrongsec/",
		"/wrongsec/Dashboard",
		"/wrongsec/dashboard",
		"/wrongsec/dashboard/",
	}
	for _, p := range wrongProbes {
		req := httptest.NewRequest("GET", p, nil)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		assert.Equal(t, http.StatusNotFound, w.Code, "wrong secret path %s must return 404", p)
	}

	// 3. Access with valid secret path:
	// 3a. GET /{secret} -> 301 redirect to /{secret}/
	reqRootNoSlash := httptest.NewRequest("GET", "/"+secret, nil)
	wRootNoSlash := httptest.NewRecorder()
	handler.ServeHTTP(wRootNoSlash, reqRootNoSlash)
	assert.Equal(t, http.StatusMovedPermanently, wRootNoSlash.Code)
	assert.Equal(t, "/"+secret+"/", wRootNoSlash.Header().Get("Location"))

	// 3b. GET /{secret}/ -> sets cookie, serves public landing page
	reqRoot := httptest.NewRequest("GET", "/"+secret+"/", nil)
	wRoot := httptest.NewRecorder()
	handler.ServeHTTP(wRoot, reqRoot)
	assert.Equal(t, http.StatusOK, wRoot.Code)
	assert.Equal(t, "welcome", wRoot.Body.String())
	cookies := wRoot.Result().Cookies()
	var secretCookie *http.Cookie
	for _, c := range cookies {
		if c.Name == SecretPathCookieName {
			secretCookie = c
			break
		}
	}
	require.NotNil(t, secretCookie, "must set nz-secret-path cookie on access with valid secret prefix")
	assert.Equal(t, secret, secretCookie.Value)

	// 3c. GET /{secret}/Dashboard (case-insensitive as requested by user) -> 301 redirect to /{secret}/dashboard/
	reqDashUpper := httptest.NewRequest("GET", "/"+secret+"/Dashboard", nil)
	wDashUpper := httptest.NewRecorder()
	handler.ServeHTTP(wDashUpper, reqDashUpper)
	assert.Equal(t, http.StatusMovedPermanently, wDashUpper.Code)
	assert.Equal(t, "/"+secret+"/dashboard/", wDashUpper.Header().Get("Location"))

	// 3d. GET /{secret}/dashboard -> 301 redirect to /{secret}/dashboard/
	reqDashLower := httptest.NewRequest("GET", "/"+secret+"/dashboard", nil)
	wDashLower := httptest.NewRecorder()
	handler.ServeHTTP(wDashLower, reqDashLower)
	assert.Equal(t, http.StatusMovedPermanently, wDashLower.Code)
	assert.Equal(t, "/"+secret+"/dashboard/", wDashLower.Header().Get("Location"))

	// 3e. GET /{secret}/dashboard/ (unauthenticated, with valid secret) -> 200 OK "dashboard-ok"
	reqDashUnauth := httptest.NewRequest("GET", "/"+secret+"/dashboard/", nil)
	wDashUnauth := httptest.NewRecorder()
	handler.ServeHTTP(wDashUnauth, reqDashUnauth)
	assert.Equal(t, http.StatusOK, wDashUnauth.Code)
	assert.Equal(t, "dashboard-ok", wDashUnauth.Body.String())

	// 3e2. GET /{secret}/dashboard/service (unauthenticated, with valid secret) -> 200 OK "dashboard-service-ok"
	reqDashSubUnauth := httptest.NewRequest("GET", "/"+secret+"/dashboard/service", nil)
	wDashSubUnauth := httptest.NewRecorder()
	handler.ServeHTTP(wDashSubUnauth, reqDashSubUnauth)
	assert.Equal(t, http.StatusOK, wDashSubUnauth.Code)
	assert.Equal(t, "dashboard-service-ok", wDashSubUnauth.Body.String())

	// 3f. GET /{secret}/dashboard/ (authenticated with nz-jwt) -> 200 OK "dashboard-ok"
	reqDashAuth := httptest.NewRequest("GET", "/"+secret+"/dashboard/", nil)
	reqDashAuth.AddCookie(&http.Cookie{Name: "nz-jwt", Value: token})
	wDashAuth := httptest.NewRecorder()
	handler.ServeHTTP(wDashAuth, reqDashAuth)
	assert.Equal(t, http.StatusOK, wDashAuth.Code)
	assert.Equal(t, "dashboard-ok", wDashAuth.Body.String())

	// 3g. POST /{secret}/api/v1/login -> 200 OK "login-ok"
	reqLogin := httptest.NewRequest("POST", "/"+secret+"/api/v1/login", nil)
	wLogin := httptest.NewRecorder()
	handler.ServeHTTP(wLogin, reqLogin)
	assert.Equal(t, http.StatusOK, wLogin.Code)
	assert.Equal(t, "login-ok", wLogin.Body.String())

	// 4. Access with nz-secret-path cookie:
	// 4a. GET /assets/app.js with cookie -> 200 OK
	reqAssetWithCookie := httptest.NewRequest("GET", "/assets/app.js", nil)
	reqAssetWithCookie.AddCookie(&http.Cookie{Name: SecretPathCookieName, Value: secret})
	wAssetWithCookie := httptest.NewRecorder()
	handler.ServeHTTP(wAssetWithCookie, reqAssetWithCookie)
	assert.Equal(t, http.StatusOK, wAssetWithCookie.Code)
	assert.Equal(t, "app.js", wAssetWithCookie.Body.String())

	// 4b. GET /api/v1/profile with secret cookie + nz-jwt -> 200 OK
	reqProfileWithCookie := httptest.NewRequest("GET", "/api/v1/profile", nil)
	reqProfileWithCookie.AddCookie(&http.Cookie{Name: SecretPathCookieName, Value: secret})
	reqProfileWithCookie.AddCookie(&http.Cookie{Name: "nz-jwt", Value: token})
	wProfileWithCookie := httptest.NewRecorder()
	handler.ServeHTTP(wProfileWithCookie, reqProfileWithCookie)
	assert.Equal(t, http.StatusOK, wProfileWithCookie.Code)
	assert.Equal(t, "profile-ok", wProfileWithCookie.Body.String())

	// 4c. GET / with cookie (naked port without secret in URL) -> 404 Not Found!
	reqRootWithCookie := httptest.NewRequest("GET", "/", nil)
	reqRootWithCookie.AddCookie(&http.Cookie{Name: SecretPathCookieName, Value: secret})
	wRootWithCookie := httptest.NewRecorder()
	handler.ServeHTTP(wRootWithCookie, reqRootWithCookie)
	assert.Equal(t, http.StatusNotFound, wRootWithCookie.Code)
	assert.Contains(t, wRootWithCookie.Body.String(), "404 page not found")

	// 4d. GET /dashboard with cookie (naked port without secret in URL) -> 404 Not Found!
	reqDashWithCookie := httptest.NewRequest("GET", "/dashboard", nil)
	reqDashWithCookie.AddCookie(&http.Cookie{Name: SecretPathCookieName, Value: secret})
	wDashWithCookie := httptest.NewRecorder()
	handler.ServeHTTP(wDashWithCookie, reqDashWithCookie)
	assert.Equal(t, http.StatusNotFound, wDashWithCookie.Code)
	assert.Contains(t, wDashWithCookie.Body.String(), "404 page not found")

	// 4e. GET /dashboard/terminal/123 with cookie -> 301 redirect to /{secret}/dashboard/terminal/123
	reqTermWithCookie := httptest.NewRequest("GET", "/dashboard/terminal/123", nil)
	reqTermWithCookie.AddCookie(&http.Cookie{Name: SecretPathCookieName, Value: secret})
	wTermWithCookie := httptest.NewRecorder()
	handler.ServeHTTP(wTermWithCookie, reqTermWithCookie)
	assert.Equal(t, http.StatusMovedPermanently, wTermWithCookie.Code)
	assert.Equal(t, "/"+secret+"/dashboard/terminal/123", wTermWithCookie.Header().Get("Location"))

	// 5. Access with PAT:
	reqPAT := httptest.NewRequest("GET", "/api/v1/server", nil)
	reqPAT.Header.Set("Authorization", "Bearer "+patPlaintext)
	wPAT := httptest.NewRecorder()
	handler.ServeHTTP(wPAT, reqPAT)
	assert.Equal(t, http.StatusOK, wPAT.Code)
	assert.Equal(t, "server-ok", wPAT.Body.String())

	// 6. OAuth2 callback path is permitted through secretPathHandler
	reqOAuthCallback := httptest.NewRequest("GET", "/api/v1/oauth2/callback", nil)
	wOAuthCallback := httptest.NewRecorder()
	handler.ServeHTTP(wOAuthCallback, reqOAuthCallback)
	assert.Equal(t, http.StatusOK, wOAuthCallback.Code)
	assert.Equal(t, "oauth2-callback-ok", wOAuthCallback.Body.String())

	// 7. Legitimate secret path access to /server and /dashboard/service/
	reqDashServiceTrailingSlash := httptest.NewRequest("GET", "/"+secret+"/dashboard/service/", nil)
	wDashServiceTrailingSlash := httptest.NewRecorder()
	handler.ServeHTTP(wDashServiceTrailingSlash, reqDashServiceTrailingSlash)
	assert.Equal(t, http.StatusOK, wDashServiceTrailingSlash.Code)
	assert.Equal(t, "dashboard-service-ok", wDashServiceTrailingSlash.Body.String())
}
