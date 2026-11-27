package main

import (
	"net/url"
	"testing"

	"github.com/openpost/backend/internal/config"
	"github.com/openpost/backend/internal/platform"
)

// tiktokScopeFromProductionRegistry builds the TikTok adapter the way main()
// does: config.Load (env) -> optional managed DB value -> providerRegistryOptions
// -> BuildAdapterRegistry over a database-style provider app config.
func tiktokScopeFromProductionRegistry(t *testing.T, storedManaged *string) string {
	t.Helper()
	cfg := config.Load()
	if storedManaged != nil {
		if err := cfg.ApplyManagedValue("OPENPOST_DISABLE_TIKTOK_DISPLAY_API", *storedManaged); err != nil {
			t.Fatalf("apply managed value: %v", err)
		}
	}
	apps := []platform.AppConfig{{
		Provider:     "tiktok",
		Name:         "tiktok",
		ClientID:     "test-client-key",
		ClientSecret: "test-client-secret",
		RedirectURI:  "https://post.example.test/api/v1/oauth/tiktok/callback",
	}}
	providers, _, err := platform.BuildAdapterRegistry(apps, providerRegistryOptions(cfg))
	if err != nil {
		t.Fatalf("build registry: %v", err)
	}
	adapter, ok := providers["tiktok"]
	if !ok {
		t.Fatalf("tiktok adapter missing from registry")
	}
	authURL, _ := adapter.GenerateAuthURL("state-123")
	parsed, err := url.Parse(authURL)
	if err != nil {
		t.Fatalf("parse auth url: %v", err)
	}
	return parsed.Query().Get("scope")
}

func TestTikTokProductionRegistryHonoursDisableDisplayAPIEnv(t *testing.T) {
	t.Setenv("OPENPOST_DISABLE_TIKTOK_DISPLAY_API", "true")
	if got, want := tiktokScopeFromProductionRegistry(t, nil), "user.info.basic,video.publish,video.upload"; got != want {
		t.Fatalf("scope = %q, want %q", got, want)
	}
}

func TestTikTokProductionRegistryDefaultsToDisplayAPIScopes(t *testing.T) {
	t.Setenv("OPENPOST_DISABLE_TIKTOK_DISPLAY_API", "")
	want := "user.info.basic,user.info.profile,user.info.stats,video.list,video.publish,video.upload"
	if got := tiktokScopeFromProductionRegistry(t, nil); got != want {
		t.Fatalf("scope = %q, want %q", got, want)
	}
}

// A value saved in Instance settings is applied after the environment, so a
// stored "false" silently re-enables the Display API scopes.
func TestTikTokProductionRegistryStoredManagedValueOverridesEnv(t *testing.T) {
	t.Setenv("OPENPOST_DISABLE_TIKTOK_DISPLAY_API", "true")
	stored := "false"
	want := "user.info.basic,user.info.profile,user.info.stats,video.list,video.publish,video.upload"
	if got := tiktokScopeFromProductionRegistry(t, &stored); got != want {
		t.Fatalf("scope = %q, want %q", got, want)
	}
	stored = "true"
	t.Setenv("OPENPOST_DISABLE_TIKTOK_DISPLAY_API", "")
	if got, want := tiktokScopeFromProductionRegistry(t, &stored), "user.info.basic,video.publish,video.upload"; got != want {
		t.Fatalf("stored true: scope = %q, want %q", got, want)
	}
}
