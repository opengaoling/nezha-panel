package controller

import (
	"net/http"
	"net/http/httptest"
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
	tok := model.APIToken{
		Common:    model.Common{ID: 10},
		UserID:    user.ID,
		Name:      "ci-pat",
		TokenHash: model.HashAPIToken(patPlaintext),
		ExpiresAt: time.Now().Add(time.Hour),
	}
	require.NoError(t, singleton.DB.Create(&tok).Error)

	reqPAT := httptest.NewRequest("GET", "/api/v1/server", nil)
	reqPAT.Header.Set("Authorization", "Bearer "+patPlaintext)
	wPAT := httptest.NewRecorder()
	r.ServeHTTP(wPAT, reqPAT)
	assert.Equal(t, http.StatusOK, wPAT.Code)
	assert.Equal(t, "server-ok", wPAT.Body.String())
}
