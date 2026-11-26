package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/labstack/echo/v4"
)

func withTrustedOrigins(t *testing.T, urls ...string) {
	t.Helper()
	SetTrustedSessionOrigins(urls...)
	t.Cleanup(func() { SetTrustedSessionOrigins() })
}

func TestCookieOriginAllowedConfiguredOriginBehindInternalHost(t *testing.T) {
	withTrustedOrigins(t, "https://post.amhar.co", "https://post.amhar.co/")
	// Proxy forwarded an internal Host and stripped X-Forwarded-Proto.
	if !cookieOriginAllowed(http.MethodPost, "https://post.amhar.co", forwardedScheme(false, ""), requestHosts("127.0.0.1:8080", "")) {
		t.Fatal("configured public origin should pass with an internal Host")
	}
	if !cookieOriginAllowed(http.MethodPost, "HTTPS://Post.Amhar.co", "http", []string{"10.0.0.5:8080"}) {
		t.Fatal("origin match should be case-insensitive")
	}
}

func TestCookieOriginAllowedForwardedProtoList(t *testing.T) {
	withTrustedOrigins(t)
	scheme := forwardedScheme(false, "https,http")
	if scheme != "https" {
		t.Fatalf("scheme = %q, want https", scheme)
	}
	if !cookieOriginAllowed(http.MethodPost, "https://post.amhar.co", scheme, requestHosts("post.amhar.co", "")) {
		t.Fatal("same-site origin with proto list should pass")
	}
	if !cookieOriginAllowed(http.MethodPost, "https://post.amhar.co", scheme, requestHosts("internal:8080", "post.amhar.co, internal")) {
		t.Fatal("same-site origin matching X-Forwarded-Host should pass")
	}
}

func TestCookieOriginRejectsForeignOrigin(t *testing.T) {
	withTrustedOrigins(t, "https://post.amhar.co")
	for _, origin := range []string{
		"https://evil.example",
		"https://post.amhar.co.evil.example",
		"https://evil.post.amhar.co",
		"https://post.amhar.co:8443",
		"https://post.amhar.co/path",
		"null",
	} {
		if cookieOriginAllowed(http.MethodPost, origin, "https", requestHosts("post.amhar.co", "")) {
			t.Errorf("origin %q should be rejected", origin)
		}
	}
	principal := &Principal{UserID: "u", SessionID: "s"}
	if !SessionOriginRejected(principal, "https://evil.example", "post.amhar.co", "https") {
		t.Fatal("SessionOriginRejected should reject a foreign origin")
	}
	if SessionOriginRejected(principal, "https://post.amhar.co", "internal:8080", "http") {
		t.Fatal("SessionOriginRejected should accept the configured origin")
	}
}

func TestCookieOriginRejectsSchemeMismatchWithoutConfigMatch(t *testing.T) {
	withTrustedOrigins(t, "https://other.example")
	if cookieOriginAllowed(http.MethodPost, "http://post.amhar.co", "https", requestHosts("post.amhar.co", "")) {
		t.Fatal("http origin on https request should be rejected")
	}
	if cookieOriginAllowed(http.MethodPost, "https://post.amhar.co", "http", requestHosts("post.amhar.co", "")) {
		t.Fatal("https origin on http request without config match should be rejected")
	}
	withTrustedOrigins(t, "https://post.amhar.co")
	if cookieOriginAllowed(http.MethodPost, "http://post.amhar.co", "http", requestHosts("internal:8080", "")) {
		t.Fatal("http variant of a configured https origin should not be trusted")
	}
}

func TestCookieOriginMissingOriginOnlySafeMethods(t *testing.T) {
	withTrustedOrigins(t, "https://post.amhar.co")
	if !cookieOriginAllowed(http.MethodGet, "", "http", nil) {
		t.Fatal("GET without Origin should pass")
	}
	if cookieOriginAllowed(http.MethodPost, "", "https", []string{"post.amhar.co"}) {
		t.Fatal("POST without Origin should be rejected")
	}
}

func TestBearerMiddlewareCookieSessionUsesConfiguredOrigin(t *testing.T) {
	withTrustedOrigins(t, "https://post.amhar.co")
	e := echo.New()
	handler := BearerMiddleware(rejectingAuthenticator{})(func(c echo.Context) error { return c.NoContent(http.StatusNoContent) })

	req := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:8080/api/v1/media/upload", nil)
	req.Header.Set("Origin", "https://evil.example")
	req.AddCookie(&http.Cookie{Name: sessionCookieName, Value: "tok"})
	rec := httptest.NewRecorder()
	_ = handler(e.NewContext(req, rec))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("foreign origin status = %d, want 403", rec.Code)
	}

	req = httptest.NewRequest(http.MethodPost, "http://127.0.0.1:8080/api/v1/media/upload", nil)
	req.Header.Set("Origin", "https://post.amhar.co")
	req.AddCookie(&http.Cookie{Name: sessionCookieName, Value: "tok"})
	rec = httptest.NewRecorder()
	_ = handler(e.NewContext(req, rec))
	if rec.Code == http.StatusForbidden {
		t.Fatal("configured origin should get past the cross-site check")
	}
}
