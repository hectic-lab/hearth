// Copyright 2026 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package v1_27

import (
	"gitea.dev/models/db"
	"gitea.dev/modules/timeutil"

	"xorm.io/xorm"
	"xorm.io/xorm/schemas"
)

type mirrorWithLastSyncUnix struct {
	LastSyncUnix int64 `xorm:"INDEX"`
}

func (mirrorWithLastSyncUnix) TableName() string {
	return "mirror"
}

func AddLastSyncUnixToMirror(x db.EngineMigration) error {
	_, err := x.SyncWithOptions(xorm.SyncOptions{
		IgnoreDropIndices: true,
	}, new(mirrorWithLastSyncUnix))
	return err
}

type heatmapContribution struct {
	ID          int64              `xorm:"pk autoincr"`
	UserID      int64              `xorm:"NOT NULL"`
	RepoID      int64              `xorm:"NOT NULL"`
	CommitSHA   string             `xorm:"VARCHAR(64) NOT NULL"`
	AuthorEmail string             `xorm:"VARCHAR(320) NOT NULL"`
	AuthorUnix  timeutil.TimeStamp `xorm:"NOT NULL"`
	CreatedUnix timeutil.TimeStamp `xorm:"created"`
	UpdatedUnix timeutil.TimeStamp `xorm:"updated"`
}

func (heatmapContribution) TableName() string {
	return "heatmap_contribution"
}

func (c *heatmapContribution) TableIndices() []*schemas.Index {
	uniqueContribution := schemas.NewIndex("repo_commit_user", schemas.UniqueType)
	uniqueContribution.AddColumn("repo_id", "commit_sha", "user_id")

	userAuthorRepo := schemas.NewIndex("u_a_r", schemas.IndexType)
	userAuthorRepo.AddColumn("user_id", "author_unix", "repo_id")

	return []*schemas.Index{uniqueContribution, userAuthorRepo}
}

// BridgeHeatmapMigrationCollision handles databases where custom migration 331
// created the heatmap table and advanced the database version past upstream 331.
func BridgeHeatmapMigrationCollision(x db.EngineMigration) error {
	hasHeatmapTable, err := x.IsTableExist(new(heatmapContribution))
	if err != nil {
		return err
	}
	if hasHeatmapTable {
		if err := AddActionRunAttemptModel(x); err != nil {
			return err
		}
	}

	if _, err := x.SyncWithOptions(xorm.SyncOptions{
		IgnoreDropIndices: true,
	}, new(heatmapContribution)); err != nil {
		return err
	}

	return AddLastSyncUnixToMirror(x)
}
