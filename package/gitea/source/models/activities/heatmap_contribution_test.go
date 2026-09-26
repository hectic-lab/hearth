// Copyright 2026 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package activities_test

import (
	"testing"

	activities_model "gitea.dev/models/activities"
	"gitea.dev/models/db"
	"gitea.dev/models/unittest"
	user_model "gitea.dev/models/user"
	"gitea.dev/modules/timeutil"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestHeatmapContributionModel(t *testing.T) {
	assert.NoError(t, unittest.PrepareTestDatabase())
	assert.NoError(t, db.TruncateBeans(t.Context(), &activities_model.HeatmapContribution{}))

	const (
		userID     = int64(2)
		repoID     = int64(1)
		commitSHA  = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		authorUnix = timeutil.TimeStamp(1579089600)
	)

	contribution := &activities_model.HeatmapContribution{
		UserID:      userID,
		RepoID:      repoID,
		CommitSHA:   commitSHA,
		AuthorEmail: "user2@example.com",
		AuthorUnix:  authorUnix,
	}
	require.NoError(t, activities_model.UpsertHeatmapContribution(t.Context(), contribution))

	count, err := activities_model.CountHeatmapContributions(t.Context(), userID)
	require.NoError(t, err)
	assert.EqualValues(t, 1, count)

	require.NoError(t, activities_model.UpsertHeatmapContribution(t.Context(), &activities_model.HeatmapContribution{
		UserID:      userID,
		RepoID:      repoID,
		CommitSHA:   commitSHA,
		AuthorEmail: "changed@example.com",
		AuthorUnix:  authorUnix + 900,
	}))

	count, err = activities_model.CountHeatmapContributions(t.Context(), userID)
	require.NoError(t, err)
	assert.EqualValues(t, 1, count)

	stored := &activities_model.HeatmapContribution{UserID: userID, RepoID: repoID, CommitSHA: commitSHA}
	has, err := db.GetEngine(t.Context()).Get(stored)
	require.NoError(t, err)
	require.True(t, has)
	assert.Equal(t, "changed@example.com", stored.AuthorEmail)
	assert.Equal(t, authorUnix+900, stored.AuthorUnix)
	assert.NotZero(t, stored.CreatedUnix)
	assert.NotZero(t, stored.UpdatedUnix)

	err = db.Insert(t.Context(), &activities_model.HeatmapContribution{
		UserID:      userID,
		RepoID:      repoID,
		CommitSHA:   commitSHA,
		AuthorEmail: "duplicate@example.com",
		AuthorUnix:  authorUnix,
	})
	assert.Error(t, err)

	includePrivate, err := user_model.GetIncludePrivateContributions(t.Context(), userID)
	require.NoError(t, err)
	assert.False(t, includePrivate)

	require.NoError(t, user_model.SetIncludePrivateContributions(t.Context(), userID, true))
	includePrivate, err = user_model.GetIncludePrivateContributions(t.Context(), userID)
	require.NoError(t, err)
	assert.True(t, includePrivate)
}
