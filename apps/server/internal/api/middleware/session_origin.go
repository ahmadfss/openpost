package middleware

import (
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
)

// trustedSessionOrigins holds the exact scheme://host origins that the server
// is configured to be served from (OPENPOST_APP_URL / OPENPOST_PUBLIC_URL).
// A cookie-authenticated request whose Origin equals one of them is same-site
// by definition, even when a TLS-terminating proxy rewrites Host or drops
// X-Forwarded-Proto before the request reaches the process.
var trustedSessionOrigins atomic.Pointer[map[string]struct{}]

// SetTrustedSessionOrigins replaces the configured public origins accepted for
// cookie-authenticated requests. Each value may be a full URL; only its scheme
// and host are kept. Values that are not absolute http(s) URLs are ignored.
func SetTrustedSessionOrigins(rawURLs ...string) {
	origins := make(map[string]struct{}, len(rawURLs))
	for _, raw := range rawURLs {
		if origin, ok := configuredOrigin(raw); ok {
			origins[origin] = struct{}{}
		}
	}
	trustedSessionOrigins.Store(&origins)
}

func configuredOrigin(raw string) (string, bool) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Host == "" || parsed.User != nil {
		return "", false
	}
	scheme := strings.ToLower(parsed.Scheme)
	if scheme != "http" && scheme != "https" {
		return "", false
	}
	return scheme + "://" + strings.ToLower(parsed.Host), true
}

func isTrustedSessionOrigin(origin string) bool {
	origins := trustedSessionOrigins.Load()
	if origins == nil {
		return false
	}
	_, ok := (*origins)[origin]
	return ok
}

// firstHeaderValue returns the first comma-separated element of a forwarding
// header, for proxies that append (e.g. "https,http").
func firstHeaderValue(value string) string {
	first, _, _ := strings.Cut(value, ",")
	return strings.TrimSpace(first)
}

// forwardedScheme reports https when TLS terminated here or the first
// X-Forwarded-Proto element is https.
func forwardedScheme(tls bool, forwardedProto string) string {
	if tls || strings.EqualFold(firstHeaderValue(forwardedProto), "https") {
		return "https"
	}
	return "http"
}

// requestHosts lists the hosts a same-site Origin may name: the first
// X-Forwarded-Host element (when a proxy supplied one) and the Host header.
func requestHosts(host, forwardedHost string) []string {
	hosts := make([]string, 0, 2)
	if forwarded := firstHeaderValue(forwardedHost); forwarded != "" {
		hosts = append(hosts, forwarded)
	}
	if host = strings.TrimSpace(host); host != "" {
		hosts = append(hosts, host)
	}
	return hosts
}

// cookieOriginAllowed is the single same-site decision for cookie sessions.
// Safe methods without an Origin pass; otherwise the Origin must be a bare
// http(s) origin that either equals a configured public origin or matches
// the request scheme and one of the request hosts. Everything else is
// rejected.
func cookieOriginAllowed(method, origin, scheme string, hosts []string) bool {
	if origin == "" {
		return method == http.MethodGet || method == http.MethodHead || method == http.MethodOptions
	}
	originURL, err := url.Parse(strings.TrimSpace(origin))
	if err != nil || originURL.Host == "" || originURL.User != nil || originURL.RawQuery != "" || originURL.Fragment != "" || originURL.Path != "" || originURL.Opaque != "" {
		return false
	}
	originScheme := strings.ToLower(originURL.Scheme)
	if originScheme != "http" && originScheme != "https" {
		return false
	}
	if isTrustedSessionOrigin(originScheme + "://" + strings.ToLower(originURL.Host)) {
		return true
	}
	if !strings.EqualFold(originScheme, scheme) {
		return false
	}
	for _, host := range hosts {
		if host != "" && strings.EqualFold(originURL.Host, strings.TrimSpace(host)) {
			return true
		}
	}
	return false
}

func sessionOriginRejectedFor(principal *Principal, origin, scheme string, hosts []string) bool {
	return principal != nil && (principal.SessionID != "" || principal.Scope == "") && origin != "" && !cookieOriginAllowed(http.MethodPost, origin, scheme, hosts)
}
