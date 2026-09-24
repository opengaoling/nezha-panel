package controller

import (
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"github.com/nezhahq/nezha/model"
	"github.com/nezhahq/nezha/service/singleton"
)

func newFrontendFallbackTestRouter(t *testing.T) *gin.Engine {
	t.Helper()
	gin.SetMode(gin.TestMode)

	originalConf := singleton.Conf
	singleton.Conf = &singleton.ConfigClass{Config: &model.Config{
		ConfigDashboard: model.ConfigDashboard{
			AdminTemplate: "admin-dist",
			UserTemplate:  "user-dist",
		},
	}}
	t.Cleanup(func() { singleton.Conf = originalConf })

	writeFrontendFallbackTestFile(t, "admin-dist/index.html", "<html>admin index</html>")
	writeFrontendFallbackTestFile(t, "admin-dist/assets/app.js", "console.log('admin asset')")
	writeFrontendFallbackTestFile(t, "user-dist/index.html", "<html>user index</html>")
	writeFrontendFallbackTestFile(t, "data/config.yaml", "jwt_secret_key: traversal-secret")

	r := gin.New()
	r.NoRoute(fallbackToFrontend(testFrontendDist{}))
	return r
}

func writeFrontendFallbackTestFile(t *testing.T, name, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
		t.Fatalf("create fixture directory: %v", err)
	}
	if err := os.WriteFile(name, []byte(content), 0o644); err != nil {
		t.Fatalf("write fixture file: %v", err)
	}
}

type testFrontendDist struct{}

func (testFrontendDist) Open(string) (fs.File, error) {
	return nil, fs.ErrNotExist
}

func performFrontendFallbackRequest(t *testing.T, router *gin.Engine, target string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, target, nil)
	router.ServeHTTP(w, req)
	return w
}

func TestFallbackToFrontendBlocksDashboardTraversal(t *testing.T) {
	t.Chdir(t.TempDir())
	router := newFrontendFallbackTestRouter(t)

	tests := []string{
		"/dashboard../data/config.yaml",
		"/dashboard%2e%2e/data/config.yaml",
		"/dashboard%2e%2e%2fdata%2fconfig.yaml",
		"/dashboard/../data/config.yaml",
		"/dashboard/%2e%2e/data/config.yaml",
		"/dashboard../assets/app.js",
	}

	for _, target := range tests {
		t.Run(target, func(t *testing.T) {
			w := performFrontendFallbackRequest(t, router, target)
			body := w.Body.String()
			if strings.Contains(body, "traversal-secret") || strings.Contains(body, "jwt_secret_key") || strings.Contains(body, "admin asset") {
				t.Fatalf("%s leaked protected content with status %d: %q", target, w.Code, body)
			}
		})
	}
}

func TestFallbackToFrontendBlocksUserTraversal(t *testing.T) {
	t.Chdir(t.TempDir())
	router := newFrontendFallbackTestRouter(t)

	tests := []string{
		"/../data/config.yaml",
		"/%2e%2e/data/config.yaml",
		"/%2e%2e%2fdata%2fconfig.yaml",
		"/../admin-dist/assets/app.js",
		"/%2e%2e/admin-dist/assets/app.js",
	}

	for _, target := range tests {
		t.Run(target, func(t *testing.T) {
			w := performFrontendFallbackRequest(t, router, target)
			body := w.Body.String()
			if strings.Contains(body, "traversal-secret") || strings.Contains(body, "jwt_secret_key") || strings.Contains(body, "admin asset") {
				t.Fatalf("%s leaked protected content with status %d: %q", target, w.Code, body)
			}
		})
	}
}

func TestFallbackToFrontendPreservesDashboardRoutes(t *testing.T) {
	t.Chdir(t.TempDir())
	router := newFrontendFallbackTestRouter(t)

	w := performFrontendFallbackRequest(t, router, "/dashboard")
	if w.Code != http.StatusMovedPermanently {
		t.Fatalf("/dashboard status = %d, want %d", w.Code, http.StatusMovedPermanently)
	}
	if location := w.Header().Get("Location"); location != "/dashboard/" {
		t.Fatalf("/dashboard Location = %q, want /dashboard/", location)
	}

	w = performFrontendFallbackRequest(t, router, "/dashboard/")
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "admin index") {
		t.Fatalf("/dashboard/ status = %d body = %q, want admin index", w.Code, w.Body.String())
	}

	w = performFrontendFallbackRequest(t, router, "/dashboard/assets/app.js")
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "admin asset") {
		t.Fatalf("/dashboard/assets/app.js status = %d body = %q, want admin asset", w.Code, w.Body.String())
	}
}

func TestFallbackToFrontendCacheBustsCustomUserAssets(t *testing.T) {
	t.Chdir(t.TempDir())
	originalVersion := singleton.Version
	originalBootTime := singleton.DashboardBootTime
	singleton.Version = "v1.2.3+cache"
	singleton.DashboardBootTime = 12345
	t.Cleanup(func() {
		singleton.Version = originalVersion
		singleton.DashboardBootTime = originalBootTime
	})

	router := newFrontendFallbackTestRouter(t)
	writeFrontendFallbackTestFile(t, "user-dist/index.html", `<html><head>
<script type="module" src="/assets/index.custom-mobile-transfer-20260611.js"></script>
<link rel="stylesheet" href="/assets/custom-user-visibility.css">
<script src="/assets/custom-scroll-tools.js"></script>
<script type="module" src="/assets/react-dom.C2KtklHg.js"></script>
</head></html>`)
	writeFrontendFallbackTestFile(t, "user-dist/assets/index.custom-mobile-transfer-20260611.js", "console.log('custom app')")
	writeFrontendFallbackTestFile(t, "user-dist/assets/custom-user-visibility.css", "body{color:red}")
	writeFrontendFallbackTestFile(t, "user-dist/assets/custom-scroll-tools.js", "console.log('scroll')")

	token := "v1-2-3-cache-" + strconv.FormatUint(12345, 36)
	w := performFrontendFallbackRequest(t, router, "/")
	body := w.Body.String()
	if w.Code != http.StatusOK {
		t.Fatalf("/ status = %d body = %q, want 200", w.Code, body)
	}
	if cacheControl := w.Header().Get("Cache-Control"); !strings.Contains(cacheControl, "no-store") {
		t.Fatalf("Cache-Control = %q, want no-store", cacheControl)
	}
	for _, expected := range []string{
		"/assets/index.custom-mobile-transfer-20260611." + token + ".js",
		"/assets/custom-user-visibility." + token + ".css",
		"/assets/custom-scroll-tools." + token + ".js",
	} {
		if !strings.Contains(body, expected) {
			t.Fatalf("index.html missing cache-busted asset %q in %q", expected, body)
		}
	}
	if !strings.Contains(body, "/assets/react-dom.C2KtklHg.js") {
		t.Fatalf("hashed vendor asset should stay unchanged, body = %q", body)
	}

	w = performFrontendFallbackRequest(t, router, "/assets/custom-user-visibility."+token+".css")
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "body{color:red}") {
		t.Fatalf("cache-busted css status = %d body = %q, want original css", w.Code, w.Body.String())
	}
	if cacheControl := w.Header().Get("Cache-Control"); !strings.Contains(cacheControl, "no-store") {
		t.Fatalf("css Cache-Control = %q, want no-store", cacheControl)
	}
	if lastMod := w.Header().Get("Last-Modified"); lastMod != "" {
		t.Fatalf("css Last-Modified = %q, want empty to prevent conditional cache", lastMod)
	}

	w = performFrontendFallbackRequest(t, router, "/assets/index.custom-mobile-transfer-20260611."+token+".js")
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "custom app") {
		t.Fatalf("cache-busted js status = %d body = %q, want original js", w.Code, w.Body.String())
	}
	if cacheControl := w.Header().Get("Cache-Control"); !strings.Contains(cacheControl, "no-store") {
		t.Fatalf("js Cache-Control = %q, want no-store", cacheControl)
	}
	if lastMod := w.Header().Get("Last-Modified"); lastMod != "" {
		t.Fatalf("js Last-Modified = %q, want empty to prevent conditional cache", lastMod)
	}
}

func TestFallbackToFrontendServesPublicUserFrontend(t *testing.T) {
	t.Chdir(t.TempDir())
	router := newFrontendFallbackTestRouter(t)

	w := performFrontendFallbackRequest(t, router, "/")
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "user index") {
		t.Fatalf("/ status = %d body = %q, want user index", w.Code, w.Body.String())
	}

	w = performFrontendFallbackRequest(t, router, "/server/42")
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "user index") {
		t.Fatalf("/server/42 status = %d body = %q, want user index", w.Code, w.Body.String())
	}

	for _, target := range []string{"/login", "/server"} {
		w = performFrontendFallbackRequest(t, router, target)
		if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "user index") {
			t.Fatalf("%s status = %d body = %q, want user index", target, w.Code, w.Body.String())
		}
	}
}
