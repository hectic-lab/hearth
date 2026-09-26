// Copyright 2026 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package repository

import (
	"context"
	"strings"

	activities_model "gitea.dev/models/activities"
	repo_model "gitea.dev/models/repo"
	user_model "gitea.dev/models/user"
	"gitea.dev/modules/git"
	"gitea.dev/modules/gitrepo"
	"gitea.dev/modules/timeutil"
)

const heatmapIndexCommitsPageSize = 100

// IndexDefaultBranchHeatmapContributions indexes commit author-date heatmap contributions reachable from repo's default branch.
func IndexDefaultBranchHeatmapContributions(ctx context.Context, repo *repo_model.Repository) error {
	if repo == nil || repo.ID == 0 {
		return nil
	}
	if repo.DefaultBranch == "" || repo.IsEmpty {
		return activities_model.DeleteStaleHeatmapContributions(ctx, repo.ID, nil)
	}

	gitRepo, closer, err := gitrepo.RepositoryFromContextOrOpen(ctx, repo)
	if err != nil {
		return err
	}
	defer closer.Close()

	head, err := gitRepo.GetBranchCommit(repo.DefaultBranch)
	if git.IsErrNotExist(err) {
		return activities_model.DeleteStaleHeatmapContributions(ctx, repo.ID, nil)
	}
	if err != nil {
		return err
	}

	currentIdentities := make([]activities_model.HeatmapContributionIdentity, 0)
	now := timeutil.TimeStampNow()
	for page := 1; ; page++ {
		commits, err := head.CommitsByRange(page, heatmapIndexCommitsPageSize, "", "", "")
		if err != nil {
			return err
		}
		if len(commits) == 0 {
			break
		}

		for _, commit := range commits {
			commitSHA := commit.ID.String()
			if commit.Author == nil || commit.Author.Email == "" {
				continue
			}

			authorUnix := timeutil.TimeStamp(commit.Author.When.Unix())
			if authorUnix > now {
				continue
			}

			userID, ok, err := getHeatmapAuthorUserIDByEmail(ctx, commit.Author.Email)
			if err != nil {
				return err
			}
			if !ok {
				continue
			}

			if err := activities_model.UpsertHeatmapContribution(ctx, &activities_model.HeatmapContribution{
				UserID:      userID,
				RepoID:      repo.ID,
				CommitSHA:   commitSHA,
				AuthorEmail: strings.ToLower(commit.Author.Email),
				AuthorUnix:  authorUnix,
			}); err != nil {
				return err
			}
			currentIdentities = append(currentIdentities, activities_model.HeatmapContributionIdentity{
				RepoID:    repo.ID,
				CommitSHA: commitSHA,
				UserID:    userID,
			})
		}

		if len(commits) < heatmapIndexCommitsPageSize {
			break
		}
	}

	return activities_model.DeleteStaleHeatmapContributions(ctx, repo.ID, currentIdentities)
}

func getHeatmapAuthorUserIDByEmail(ctx context.Context, email string) (int64, bool, error) {
	address, err := user_model.GetEmailAddressByEmail(ctx, email)
	if user_model.IsErrEmailAddressNotExist(err) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	if !address.IsActivated {
		return 0, false, nil
	}
	return address.UID, true, nil
}
