// Copyright 2018 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package integration

import (
	"net/http"
	"testing"
	"time"

	activities_model "gitea.dev/models/activities"
	auth_model "gitea.dev/models/auth"
	"gitea.dev/models/db"
	user_model "gitea.dev/models/user"
	"gitea.dev/modules/timeutil"
	"gitea.dev/tests"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestUserHeatmap(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	adminUsername := "user1"
	normalUsername := "user2"
	token := getUserToken(t, adminUsername, auth_model.AccessTokenScopeReadUser)

	fakeNow := time.Date(2011, 10, 21, 0, 0, 0, 0, time.Local)
	timeutil.MockSet(fakeNow)
	defer timeutil.MockUnset()

	require.NoError(t, db.TruncateBeans(t.Context(), &activities_model.HeatmapContribution{}))
	require.NoError(t, user_model.SetIncludePrivateContributions(t.Context(), 2, false))
	testHeatmapSeedContribution(t, 2, 1, "api-user2-public-author-date", 1319068800)
	testHeatmapSeedContribution(t, 2, 1, "api-user2-public-same-bucket", 1319068850)
	testHeatmapSeedContribution(t, 2, 2, "api-user2-private-hidden", 1319070600)

	req := NewRequestf(t, "GET", "/api/v1/users/%s/heatmap", normalUsername).
		AddTokenAuth(token)
	resp := MakeRequest(t, req, http.StatusOK)
	heatmap := DecodeJSON(t, resp, []*activities_model.UserHeatmapData{})

	assert.Equal(t, []*activities_model.UserHeatmapData{
		{Timestamp: 1319068800, Contributions: 2},
	}, heatmap)
}
