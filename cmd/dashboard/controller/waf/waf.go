package waf

import (
	_ "embed"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/nezhahq/nezha/model"
	"github.com/nezhahq/nezha/pkg/utils"
	"github.com/nezhahq/nezha/service/singleton"
)

//go:embed waf.html
var errorPageTemplate string

func RealIp(c *gin.Context) {
	if singleton.Conf.WebRealIPHeader == "" {
		c.Next()
		return
	}

	if singleton.Conf.WebRealIPHeader == model.ConfigUsePeerIP {
		c.Set(model.CtxKeyRealIPStr, c.RemoteIP())
		c.Next()
		return
	}

	vals := c.Request.Header.Get(singleton.Conf.WebRealIPHeader)
	if vals == "" {
		c.AbortWithStatusJSON(http.StatusOK, model.CommonResponse[any]{Success: false, Error: "real ip header not found"})
		return
	}
	ip, err := utils.GetIPFromHeader(vals)
	if err != nil {
		c.AbortWithStatusJSON(http.StatusOK, model.CommonResponse[any]{Success: false, Error: err.Error()})
		return
	}
	c.Set(model.CtxKeyRealIPStr, ip)
	c.Next()
}

// AntiProbeGuard is an optional checker invoked by WAF to protect internal
// paths from unauthenticated probing. It returns true if the request is
// allowed to proceed, or false if it was rejected with a 404 response.
var AntiProbeGuard func(c *gin.Context) bool

func Waf(c *gin.Context) {
	if err := model.CheckIP(singleton.DB, c.GetString(model.CtxKeyRealIPStr)); err != nil {
		ShowBlockPage(c, err)
		return
	}
	if AntiProbeGuard != nil && !AntiProbeGuard(c) {
		return
	}
	c.Next()
}

func ShowBlockPage(c *gin.Context, err error) {
	var errMsg string
	if err != nil {
		errMsg = err.Error()
	} else {
		errMsg = "you were blocked by nezha WAF"
	}
	c.Writer.WriteHeader(http.StatusForbidden)
	c.Header("Content-Type", "text/html; charset=utf-8")
	c.Writer.WriteString(strings.Replace(errorPageTemplate, "{error}", errMsg, 1))
	c.Abort()
}
