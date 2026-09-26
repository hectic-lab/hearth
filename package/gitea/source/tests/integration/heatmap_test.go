// Copyright 2026 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package integration

import (
	"crypto/sha1"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	activities_model "gitea.dev/models/activities"
	"gitea.dev/models/db"
	user_model "gitea.dev/models/user"
	"gitea.dev/modules/json"
	"gitea.dev/modules/timeutil"
	"gitea.dev/tests"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type testHeatmapWebResponse struct {
	HeatmapData        [][2]int64 `json:"heatmapData"`
	TotalContributions int64      `json:"totalContributions"`
}

func TestHeatmapEndpoints(t *testing.T) {
	defer tests.PrepareTestEnv(t)()

	// Mock time so fixture actions fall within the heatmap's time window
	timeutil.MockSet(time.Date(2021, 1, 1, 0, 0, 0, 0, time.UTC))
	defer timeutil.MockUnset()
	require.NoError(t, db.TruncateBeans(t.Context(), &activities_model.HeatmapContribution{}))
	require.NoError(t, user_model.SetIncludePrivateContributions(t.Context(), 2, false))
	testHeatmapSeedContribution(t, 2, 1, "web-user2-public-one", 1603009800)
	testHeatmapSeedContribution(t, 2, 1, "web-user2-public-two", 1603009850)
	testHeatmapSeedContribution(t, 2, 2, "web-user2-private-hidden", 1603010700)

	session := loginUser(t, "user2")

	t.Run("UserProfile", func(t *testing.T) {
		defer tests.PrintCurrentTest(t)()
		req := NewRequest(t, "GET", "/user2/-/heatmap")
		resp := session.MakeRequest(t, req, http.StatusOK)

		webHeatmap := testHeatmapDecodeWebResponse(t, resp)

		req = NewRequest(t, "GET", "/api/v1/users/user2/heatmap")
		resp = session.MakeRequest(t, req, http.StatusOK)
		apiHeatmap := DecodeJSON(t, resp, []*activities_model.UserHeatmapData{})

		assert.Equal(t, testHeatmapSumAPIContributions(apiHeatmap), webHeatmap.TotalContributions)
		assert.Equal(t, int64(2), webHeatmap.TotalContributions)
	})

	t.Run("OrgDashboard", func(t *testing.T) {
		defer tests.PrintCurrentTest(t)()
		req := NewRequest(t, "GET", "/org/org3/dashboard/-/heatmap")
		resp := session.MakeRequest(t, req, http.StatusOK)

		result := DecodeJSON(t, resp, map[string]any{})
		assert.Contains(t, result, "heatmapData")
		assert.Contains(t, result, "totalContributions")
	})

	t.Run("OrgTeamDashboard", func(t *testing.T) {
		defer tests.PrintCurrentTest(t)()
		req := NewRequest(t, "GET", "/org/org3/dashboard/-/heatmap/team1")
		resp := session.MakeRequest(t, req, http.StatusOK)

		result := DecodeJSON(t, resp, map[string]any{})
		assert.Contains(t, result, "heatmapData")
		assert.Contains(t, result, "totalContributions")
	})
}

func testHeatmapSeedContribution(t *testing.T, userID, repoID int64, label string, authorUnix timeutil.TimeStamp) string {
	t.Helper()

	commitSHA := fmt.Sprintf("%040x", sha1.Sum([]byte(label)))
	require.NoError(t, activities_model.UpsertHeatmapContribution(t.Context(), &activities_model.HeatmapContribution{
		UserID:      userID,
		RepoID:      repoID,
		CommitSHA:   commitSHA,
		AuthorEmail: fmt.Sprintf("user%d@example.com", userID),
		AuthorUnix:  authorUnix,
	}))
	return commitSHA
}

func testHeatmapDecodeWebResponse(t *testing.T, resp *httptest.ResponseRecorder) testHeatmapWebResponse {
	t.Helper()

	var result testHeatmapWebResponse
	DecodeJSON(t, resp, &result)
	return result
}

func testHeatmapSumAPIContributions(heatmap []*activities_model.UserHeatmapData) int64 {
	var total int64
	for _, item := range heatmap {
		total += item.Contributions
	}
	return total
}

func testHeatmapAssertAggregateOnlyAPIResponse(t *testing.T, body []byte) {
	t.Helper()

	var decoded []map[string]any
	require.NoError(t, json.Unmarshal(body, &decoded))
	for _, entry := range decoded {
		assert.ElementsMatch(t, []string{"timestamp", "contributions"}, testHeatmapMapKeys(entry))
	}
}

func testHeatmapAssertAggregateOnlyWebResponse(t *testing.T, body []byte) {
	t.Helper()

	var decoded map[string]any
	require.NoError(t, json.Unmarshal(body, &decoded))
	assert.ElementsMatch(t, []string{"heatmapData", "totalContributions"}, testHeatmapMapKeys(decoded))
}

func testHeatmapAssertNoPrivateMetadata(t *testing.T, body []byte, forbidden ...string) {
	t.Helper()

	response := string(body)
	for _, value := range forbidden {
		assert.NotContains(t, response, value)
	}
	for _, value := range []string{"repo_id", "repository_id", "repoID", "commit_sha", "commit_message", "branch", "url", "action_id"} {
		assert.NotContains(t, response, value)
	}
}

func testHeatmapMapKeys[K comparable, V any](m map[K]V) []K {
	keys := make([]K, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	return keys
}
