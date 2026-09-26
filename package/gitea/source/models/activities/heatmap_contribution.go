// Copyright 2026 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package activities

import (
	"context"

	"gitea.dev/models/db"
	"gitea.dev/modules/timeutil"

	"xorm.io/xorm/schemas"
)

// HeatmapContribution stores commit contributions counted for profile heatmaps.
type HeatmapContribution struct {
	ID          int64              `xorm:"pk autoincr"`
	UserID      int64              `xorm:"NOT NULL"`
	RepoID      int64              `xorm:"NOT NULL"`
	CommitSHA   string             `xorm:"VARCHAR(64) NOT NULL"`
	AuthorEmail string             `xorm:"VARCHAR(320) NOT NULL"`
	AuthorUnix  timeutil.TimeStamp `xorm:"NOT NULL"`
	CreatedUnix timeutil.TimeStamp `xorm:"created"`
	UpdatedUnix timeutil.TimeStamp `xorm:"updated"`
}

// HeatmapContributionIdentity identifies the counted contribution row that remains valid after reindexing.
type HeatmapContributionIdentity struct {
	RepoID    int64
	CommitSHA string
	UserID    int64
}

func init() {
	db.RegisterModel(new(HeatmapContribution))
}

// TableIndices implements xorm's TableIndices interface.
func (c *HeatmapContribution) TableIndices() []*schemas.Index {
	uniqueContribution := schemas.NewIndex("repo_commit_user", schemas.UniqueType)
	uniqueContribution.AddColumn("repo_id", "commit_sha", "user_id")

	userAuthorRepo := schemas.NewIndex("u_a_r", schemas.IndexType)
	userAuthorRepo.AddColumn("user_id", "author_unix", "repo_id")

	return []*schemas.Index{uniqueContribution, userAuthorRepo}
}

// UpsertHeatmapContribution creates or updates a commit contribution without duplicating counted rows.
func UpsertHeatmapContribution(ctx context.Context, contribution *HeatmapContribution) error {
	return db.WithTx(ctx, func(ctx context.Context) error {
		e := db.GetEngine(ctx)

		rows, err := e.Where("repo_id=? AND commit_sha=? AND user_id=?", contribution.RepoID, contribution.CommitSHA, contribution.UserID).
			Cols("author_email", "author_unix").
			Update(contribution)
		if err != nil {
			return err
		}
		if rows > 0 {
			return nil
		}

		has, err := e.Exist(&HeatmapContribution{RepoID: contribution.RepoID, CommitSHA: contribution.CommitSHA, UserID: contribution.UserID})
		if err != nil {
			return err
		}
		if has {
			return nil
		}

		_, err = e.Insert(contribution)
		return err
	})
}

// CountHeatmapContributions returns counted heatmap contribution rows for a user.
func CountHeatmapContributions(ctx context.Context, userID int64) (int64, error) {
	return db.GetEngine(ctx).Where("user_id=?", userID).Count(new(HeatmapContribution))
}

// DeleteStaleHeatmapContributions removes indexed rows not found in the current eligible contribution identities.
func DeleteStaleHeatmapContributions(ctx context.Context, repoID int64, identities []HeatmapContributionIdentity) error {
	if len(identities) == 0 {
		_, err := db.GetEngine(ctx).Where("repo_id=?", repoID).Delete(new(HeatmapContribution))
		return err
	}

	current := make(map[HeatmapContributionIdentity]struct{}, len(identities))
	for _, identity := range identities {
		current[identity] = struct{}{}
	}

	contributions, err := FindHeatmapContributionsByRepo(ctx, repoID)
	if err != nil {
		return err
	}
	for _, contribution := range contributions {
		identity := HeatmapContributionIdentity{
			RepoID:    contribution.RepoID,
			CommitSHA: contribution.CommitSHA,
			UserID:    contribution.UserID,
		}
		if _, ok := current[identity]; ok {
			continue
		}
		if _, err := db.GetEngine(ctx).ID(contribution.ID).Delete(new(HeatmapContribution)); err != nil {
			return err
		}
	}
	return nil
}

// FindHeatmapContributionsByRepo returns indexed contribution rows for a repository.
func FindHeatmapContributionsByRepo(ctx context.Context, repoID int64) ([]*HeatmapContribution, error) {
	contributions := make([]*HeatmapContribution, 0)
	return contributions, db.GetEngine(ctx).
		Where("repo_id=?", repoID).
		OrderBy("author_unix ASC, commit_sha ASC, user_id ASC").
		Find(&contributions)
}
