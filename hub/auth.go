package hub

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
	"unicode"
)

// Authenticator finds the media server user behind a device's credentials. ok is false when the
// media server rejects them. err is set when it can't be asked (network error, HTTP 5xx), so the
// hub can tell a wrong password from "try again later".
type Authenticator func(ctx context.Context, auth Auth) (user string, ok bool, err error)

// UpstreamKind is the kind of media server behind the hub.
type UpstreamKind string

const (
	KindNavidrome UpstreamKind = "navidrome" // Subsonic API, plus the Jellyfin API at /jellyfin
	KindSubsonic  UpstreamKind = "subsonic"
	KindJellyfin  UpstreamKind = "jellyfin"
)

// DevAuthenticator accepts anyone: Subsonic credentials as the username they claim, anything else
// as "dev". For demos and tests only.
func DevAuthenticator(_ context.Context, auth Auth) (string, bool, error) {
	if auth.Scheme == "subsonic" {
		return auth.Username, true, nil
	}
	return "dev", true, nil
}

const clientName = "segue-hub"

// UpstreamAuthenticator checks credentials with the media server itself, so the hub keeps no users
// or passwords of its own. Successful checks are cached for cacheFor.
func UpstreamAuthenticator(kind UpstreamKind, baseURL string, cacheFor time.Duration) Authenticator {
	base := strings.TrimRight(baseURL, "/")
	jellyfinBase := base
	if kind == KindNavidrome {
		jellyfinBase += "/jellyfin"
	}
	client := &http.Client{Timeout: 5 * time.Second}

	check := func(ctx context.Context, auth Auth) (string, bool, error) {
		if auth.Scheme == "jellyfin" {
			if kind == KindSubsonic || strings.ContainsAny(auth.Token, `"\`) || strings.IndexFunc(auth.Token, unicode.IsControl) >= 0 {
				return "", false, nil
			}
			var me struct{ Name string }
			// Token only, without Client/Device: Navidrome then doesn't list the hub among its players.
			header := http.Header{"Authorization": {`MediaBrowser Token="` + auth.Token + `"`}}
			found, err := getJSON(ctx, client, jellyfinBase+"/Users/Me", header, &me)
			return me.Name, found && me.Name != "", err
		}
		if kind == KindJellyfin {
			return "", false, nil
		}
		query := url.Values{"v": {"1.16.1"}, "c": {clientName}, "f": {"json"}}
		endpoint := "ping"
		if auth.Scheme == "subsonic" {
			query.Set("u", auth.Username)
			query.Set("t", auth.Token)
			query.Set("s", auth.Salt)
		} else {
			// An API key doesn't say whose it is: tokenInfo (OpenSubsonic apiKeyAuthentication) does.
			query.Set("apiKey", auth.APIKey)
			endpoint = "tokenInfo"
		}
		var body struct {
			Response struct {
				Status    string `json:"status"`
				TokenInfo struct {
					Username string `json:"username"`
				} `json:"tokenInfo"`
			} `json:"subsonic-response"`
		}
		found, err := getJSON(ctx, client, base+"/rest/"+endpoint+".view?"+query.Encode(), nil, &body)
		if !found || body.Response.Status != "ok" {
			return "", false, err
		}
		if auth.Scheme == "subsonic" {
			return auth.Username, true, nil
		}
		return body.Response.TokenInfo.Username, body.Response.TokenInfo.Username != "", nil
	}

	type cached struct {
		user  string
		until time.Time
	}
	var mu sync.Mutex
	cache := map[[32]byte]cached{}
	return func(ctx context.Context, auth Auth) (string, bool, error) {
		raw, _ := json.Marshal(auth)
		key := sha256.Sum256(raw)
		now := time.Now()
		mu.Lock()
		hit, found := cache[key]
		mu.Unlock()
		if found && now.Before(hit.until) {
			return hit.user, true, nil
		}
		user, ok, err := check(ctx, auth)
		if ok {
			mu.Lock()
			if len(cache) >= 1000 {
				for k, v := range cache {
					if !now.Before(v.until) {
						delete(cache, k)
					}
				}
			}
			cache[key] = cached{user, now.Add(cacheFor)}
			mu.Unlock()
		}
		return user, ok, err
	}
}

// getJSON decodes a JSON answer into out. found is false for 401 and 403; other failures are errors.
func getJSON(ctx context.Context, client *http.Client, target string, header http.Header, out any) (found bool, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return false, err
	}
	if header != nil {
		req.Header = header
	}
	endpoint, _, _ := strings.Cut(target, "?")
	res, err := client.Do(req)
	if err != nil {
		var urlErr *url.Error
		if errors.As(err, &urlErr) {
			err = urlErr.Err // its message has the whole URL, credentials included
		}
		return false, fmt.Errorf("%s: %w", endpoint, err)
	}
	defer res.Body.Close()
	switch {
	case res.StatusCode == http.StatusUnauthorized || res.StatusCode == http.StatusForbidden:
		return false, nil
	case res.StatusCode/100 != 2:
		return false, fmt.Errorf("%s: HTTP %d", endpoint, res.StatusCode)
	}
	if err := json.NewDecoder(res.Body).Decode(out); err != nil {
		return false, fmt.Errorf("%s: %w", endpoint, err)
	}
	return true, nil
}
