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

// MediaServerKind is the kind of media server behind the hub.
type MediaServerKind string

// The kinds of media server the hub works with.
const (
	KindNavidrome MediaServerKind = "navidrome" // Subsonic API, plus the Jellyfin API at /jellyfin
	KindSubsonic  MediaServerKind = "subsonic"
	KindJellyfin  MediaServerKind = "jellyfin"
)

// ErrNotAMediaServer is DetectMediaServer's answer for a URL that answers, but as neither a
// Subsonic nor a Jellyfin server.
var ErrNotAMediaServer = errors.New("hub: neither a Subsonic nor a Jellyfin server")

// DetectMediaServer asks the media server at baseURL what it is: its answer to a Subsonic ping
// without credentials (whose OpenSubsonic type says Navidrome), or else to Jellyfin's public system
// info. Any error other than ErrNotAMediaServer means it couldn't be asked (network error, HTTP
// 5xx), and asking again may work.
func DetectMediaServer(ctx context.Context, baseURL string) (MediaServerKind, error) {
	base := strings.TrimRight(baseURL, "/")
	client := &http.Client{Timeout: 5 * time.Second}

	var ping struct {
		Response *struct {
			Type string `json:"type"`
		} `json:"subsonic-response"`
	}

	subsonicErr := probe(ctx, client, base+"/rest/ping.view?v=1.16.1&c="+clientName+"&f=json", &ping)
	if subsonicErr == nil && ping.Response != nil {
		if ping.Response.Type == "navidrome" {
			return KindNavidrome, nil
		}

		return KindSubsonic, nil
	}

	var info struct {
		ID string `json:"Id"`
	}

	jellyfinErr := probe(ctx, client, base+"/System/Info/Public", &info)
	if jellyfinErr == nil && info.ID != "" {
		return KindJellyfin, nil
	}

	for _, err := range []error{subsonicErr, jellyfinErr} {
		if err != nil && !errors.Is(err, errNotThere) {
			return "", err
		}
	}

	return "", ErrNotAMediaServer
}

// errNotThere is probe's answer for an endpoint that answers, but not with JSON.
var errNotThere = errors.New("not there")

// probe decodes a JSON answer into out. It returns errNotThere for an HTTP 4xx or an answer that
// isn't JSON, and other errors for a failure that may go away.
func probe(ctx context.Context, client *http.Client, target string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return err
	}

	endpoint, _, _ := strings.Cut(target, "?")
	res, err := client.Do(req)
	if err != nil {
		var urlErr *url.Error
		if errors.As(err, &urlErr) {
			err = urlErr.Err // its message repeats the URL
		}

		return fmt.Errorf("%s: %w", endpoint, err)
	}

	defer res.Body.Close()

	switch {
	case res.StatusCode/100 == 4:
		return errNotThere
	case res.StatusCode/100 != 2:
		return fmt.Errorf("%s: HTTP %d", endpoint, res.StatusCode)
	}

	if json.NewDecoder(res.Body).Decode(out) != nil {
		return errNotThere
	}

	return nil
}

// DevAuthenticator accepts anyone: Subsonic credentials as the username they claim, anything else
// as "dev". For demos and tests only.
func DevAuthenticator(_ context.Context, auth Auth) (string, bool, error) {
	if auth.Scheme == SchemeSubsonic {
		return auth.Username, true, nil
	}

	return "dev", true, nil
}

const clientName = "segue-hub"

// jellyfinBase is where the media server at baseURL has its Jellyfin API.
func jellyfinBase(kind MediaServerKind, baseURL string) string {
	base := strings.TrimRight(baseURL, "/")

	if kind == KindNavidrome {
		return base + "/jellyfin"
	}

	return base
}

// MediaServerAuthenticator checks credentials with the media server itself, so the hub keeps no
// users or passwords of its own. Successful checks are cached for cacheFor.
func MediaServerAuthenticator(kind MediaServerKind, baseURL string, cacheFor time.Duration) Authenticator {
	base := strings.TrimRight(baseURL, "/")
	jellyfinBaseURL := jellyfinBase(kind, baseURL)
	client := &http.Client{Timeout: 5 * time.Second}

	check := func(ctx context.Context, auth Auth) (string, bool, error) {
		if auth.Scheme == SchemeJellyfin {
			if kind == KindSubsonic || strings.ContainsAny(auth.Token, `"\`) || strings.IndexFunc(auth.Token, unicode.IsControl) >= 0 {
				return "", false, nil
			}

			var me struct{ Name string }

			// Token only, without Client/Device: Navidrome then doesn't list the hub among its players.
			header := http.Header{"Authorization": {`MediaBrowser Token="` + auth.Token + `"`}}
			found, err := getJSON(ctx, client, jellyfinBaseURL+"/Users/Me", header, &me)
			return me.Name, found && me.Name != "", err
		}

		if kind == KindJellyfin {
			return "", false, nil
		}

		query := subsonicQuery(auth, clientName)
		endpoint := "ping"

		if auth.Scheme != SchemeSubsonic {
			// An API key doesn't say whose it is: tokenInfo (OpenSubsonic apiKeyAuthentication) does.
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

		if auth.Scheme == SchemeSubsonic {
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

// subsonicQuery is the query of a Subsonic API call made with auth (subsonic or apiKey) by client.
func subsonicQuery(auth Auth, client string) url.Values {
	query := url.Values{"v": {"1.16.1"}, "c": {client}, "f": {"json"}}

	if auth.Scheme == SchemeSubsonic {
		query.Set("u", auth.Username)
		query.Set("t", auth.Token)
		query.Set("s", auth.Salt)
	} else {
		query.Set("apiKey", auth.APIKey)
	}

	return query
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
