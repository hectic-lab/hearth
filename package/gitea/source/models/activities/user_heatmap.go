// Copyright 2018 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package activities

import (
	"context"

	"gitea.dev/models/db"
	"gitea.dev/models/organization"
	user_model "gitea.dev/models/user"
	"gitea.dev/modules/setting"
	"gitea.dev/modules/structs"
	"gitea.dev/modules/timeutil"
)

// UserHeatmapData represents the data needed to create a heatmap
type UserHeatmapData struct {
	Timestamp     timeutil.TimeStamp `json:"timestamp"`
	Contributions int64              `json:"contributions"`
}

// GetUserHeatmapDataByUser returns an array of UserHeatmapData, it checks whether doer can access user's activity
func GetUserHeatmapDataByUser(ctx context.Context, user, doer *user_model.User) ([]*UserHeatmapData, error) {
	return getUserHeatmapData(ctx, user, nil, doer)
}

// GetUserHeatmapDataByOrgTeam returns an array of UserHeatmapData, it checks whether doer can access org's activity
func GetUserHeatmapDataByOrgTeam(ctx context.Context, org *organization.Organization, team *organization.Team, doer *user_model.User) ([]*UserHeatmapData, error) {
	return getUserHeatmapData(ctx, org.AsUser(), team, doer)
}

func getUserHeatmapData(ctx context.Context, user *user_model.User, team *organization.Team, doer *user_model.User) ([]*UserHeatmapData, error) {
	hdata := make([]*UserHeatmapData, 0)

	if !ActivityReadable(user, doer) {
		return hdata, nil
	}

	// Group by 15 minute intervals which will allow the client to accurately shift the timestamp to their timezone.
	// The interval is based on the fact that there are timezones such as UTC +5:30 and UTC +12:45.
	groupBy := "author_unix / 900 * 900"
	groupByName := "timestamp" // We need this extra case because mssql doesn't allow grouping by alias
	switch {
	case setting.Database.Type.IsMySQL():
		groupBy = "author_unix DIV 900 * 900"
	case setting.Database.Type.IsMSSQL():
		groupByName = groupBy
	}

	includePrivate, err := user_model.GetIncludePrivateContributions(ctx, user.ID)
	if err != nil {
		return nil, err
	}

	sess := db.GetEngine(ctx).
		Select(groupBy+" AS timestamp, count(heatmap_contribution.user_id) as contributions").
		Table("heatmap_contribution").
		Join("INNER", "repository", "repository.id = heatmap_contribution.repo_id").
		Join("INNER", "`user` AS repo_owner", "repo_owner.id = repository.owner_id").
		Where("author_unix > ?", timeutil.TimeStampNow()-(366+7)*86400). // (366+7) days to include the first week for the heatmap
		And("author_unix <= ?", timeutil.TimeStampNow())

	if !includePrivate {
		sess = sess.And("repository.is_private = ?", false).
			And("repo_owner.visibility = ?", structs.VisibleTypePublic)
	}

	if user.IsOrganization() {
		sess = sess.And("repository.owner_id = ?", user.ID)
		if team != nil && !team.IncludesAllRepositories {
			sess = sess.Join("INNER", "team_repo", "team_repo.repo_id = repository.id").
				And("team_repo.org_id = ?", team.OrgID).
				And("team_repo.team_id = ?", team.ID)
		}
	} else {
		sess = sess.And("heatmap_contribution.user_id = ?", user.ID)
	}

	return hdata, sess.
		GroupBy(groupByName).
		OrderBy("timestamp").
		Find(&hdata)
}
