// Copyright 2026 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package repository

import (
	"fmt"
	"strings"
	"testing"
	"time"

	activities_model "gitea.dev/models/activities"
	"gitea.dev/models/db"
	repo_model "gitea.dev/models/repo"
	"gitea.dev/models/unittest"
	user_model "gitea.dev/models/user"
	"gitea.dev/modules/git"
	"gitea.dev/modules/git/gitcmd"
	"gitea.dev/modules/queue"
	repo_module "gitea.dev/modules/repository"
	"gitea.dev/modules/timeutil"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestHeatmapIndexDefaultBranchAuthorDates(t *testing.T) {
	repo, commits := prepareHeatmapIndexRepo(t, "heatmap-author-dates", []heatmapIndexTestCommit{
		{Branch: "main", Mark: "old", AuthorName: "User Two", AuthorEmail: "user2@example.com", CommitterName: "User One", CommitterEmail: "user1@example.com", AuthorDate: "2020-01-15T12:00:00Z"},
		{Branch: "main", Mark: "unknown", AuthorName: "Unknown", AuthorEmail: "unknown@example.com", CommitterName: "User One", CommitterEmail: "user1@example.com", AuthorDate: "2020-01-16T12:00:00Z"},
		{Branch: "main", Mark: "future", AuthorName: "User Two", AuthorEmail: "user2@example.com", CommitterName: "User One", CommitterEmail: "user1@example.com", AuthorDate: "2030-01-15T12:00:00Z"},
	})

	timeutil.MockSet(time.Date(2026, 6, 6, 0, 0, 0, 0, time.UTC))
	defer timeutil.MockUnset()

	require.NoError(t, IndexDefaultBranchHeatmapContributions(t.Context(), repo))
	require.NoError(t, IndexDefaultBranchHeatmapContributions(t.Context(), repo))

	contributions := loadHeatmapContributionsForRepo(t, repo.ID)
	require.Len(t, contributions, 1)
	assert.Equal(t, int64(2), contributions[0].UserID)
	assert.Equal(t, commits["old"], contributions[0].CommitSHA)
	assert.Equal(t, "user2@example.com", contributions[0].AuthorEmail)
	assert.Equal(t, timeutil.TimeStamp(1579089600), contributions[0].AuthorUnix)

	emailAddress, err := user_model.GetEmailAddressByEmail(t.Context(), "user2@example.com")
	require.NoError(t, err)
	emailAddress.UID = 1
	_, err = db.GetEngine(t.Context()).ID(emailAddress.ID).Cols("uid").Update(emailAddress)
	require.NoError(t, err)
	require.NoError(t, IndexDefaultBranchHeatmapContributions(t.Context(), repo))

	contributions = loadHeatmapContributionsForRepo(t, repo.ID)
	require.Len(t, contributions, 1)
	assert.Equal(t, int64(1), contributions[0].UserID)
	assert.Equal(t, commits["old"], contributions[0].CommitSHA)
}

func TestHeatmapIndexIgnoresPusherAndNonDefaultBranch(t *testing.T) {
	repo, commits := prepareHeatmapIndexRepo(t, "heatmap-exclusions", []heatmapIndexTestCommit{
		{Branch: "main", Mark: "author-user2", AuthorName: "User Two", AuthorEmail: "user2@example.com", CommitterName: "User One", CommitterEmail: "user1@example.com", AuthorDate: "2020-01-15T12:00:00Z"},
		{Branch: "main", Mark: "author-user1", AuthorName: "User One", AuthorEmail: "user1@example.com", CommitterName: "User Two", CommitterEmail: "user2@example.com", AuthorDate: "2020-01-16T12:00:00Z"},
		{Branch: "feature", Mark: "feature-only", AuthorName: "User Two", AuthorEmail: "user2@example.com", CommitterName: "User Two", CommitterEmail: "user2@example.com", AuthorDate: "2020-01-17T12:00:00Z"},
	})

	timeutil.MockSet(time.Date(2026, 6, 6, 0, 0, 0, 0, time.UTC))
	defer timeutil.MockUnset()

	require.NoError(t, IndexDefaultBranchHeatmapContributions(t.Context(), repo))

	contributions := loadHeatmapContributionsForRepo(t, repo.ID)
	require.Len(t, contributions, 2)
	assert.Equal(t, int64(2), contributions[0].UserID)
	assert.Equal(t, commits["author-user2"], contributions[0].CommitSHA)
	assert.Equal(t, int64(1), contributions[1].UserID)
	assert.Equal(t, commits["author-user1"], contributions[1].CommitSHA)
	for _, contribution := range contributions {
		assert.NotEqual(t, commits["feature-only"], contribution.CommitSHA)
	}

	deleteMainRef(t, repo)
	require.NoError(t, IndexDefaultBranchHeatmapContributions(t.Context(), repo))
	assert.Empty(t, loadHeatmapContributionsForRepo(t, repo.ID))
}

func TestHeatmapIndexOnPushDefaultBranch(t *testing.T) {
	previousLicenseUpdaterQueue := licenseUpdaterQueue
	licenseUpdaterQueue = queue.CreateUniqueQueue[*LicenseUpdaterOptions](t.Context(), "heatmap_test_license_updater", nil)
	require.NotNil(t, licenseUpdaterQueue)
	defer func() {
		licenseUpdaterQueue = previousLicenseUpdaterQueue
	}()

	repo, commits := prepareHeatmapIndexRepo(t, "heatmap-push-default", []heatmapIndexTestCommit{
		{Branch: "main", Mark: "initial", AuthorName: "User Two", AuthorEmail: "user2@example.com", CommitterName: "User One", CommitterEmail: "user1@example.com", AuthorDate: "2020-01-15T12:00:00Z"},
	})

	timeutil.MockSet(time.Date(2026, 6, 6, 0, 0, 0, 0, time.UTC))
	defer timeutil.MockUnset()

	require.NoError(t, IndexDefaultBranchHeatmapContributions(t.Context(), repo))
	assert.Len(t, loadHeatmapContributionsForRepo(t, repo.ID), 1)

	newCommits := runFastImport(t, repo, []heatmapIndexTestCommit{
		{Branch: "main", Mark: "pushed", Parent: commits["initial"], AuthorName: "User Two", AuthorEmail: "user2@example.com", CommitterName: "User One", CommitterEmail: "user1@example.com", AuthorDate: "2020-01-16T12:00:00Z"},
	})
	require.NoError(t, pushQueueHandleUpdates([]*repo_module.PushUpdateOptions{
		{
			RefFullName:  git.RefNameFromBranch("main"),
			OldCommitID:  commits["initial"],
			NewCommitID:  newCommits["pushed"],
			PusherID:     1,
			RepoUserName: repo.OwnerName,
			RepoName:     repo.Name,
		},
	}))

	contributions := loadHeatmapContributionsForRepo(t, repo.ID)
	require.Len(t, contributions, 2)
	assert.Equal(t, newCommits["pushed"], contributions[1].CommitSHA)

	require.NoError(t, db.TruncateBeans(t.Context(), &activities_model.HeatmapContribution{}))
	featureCommits := runFastImport(t, repo, []heatmapIndexTestCommit{
		{Branch: "feature", Mark: "feature-pushed", AuthorName: "User Two", AuthorEmail: "user2@example.com", CommitterName: "User One", CommitterEmail: "user1@example.com", AuthorDate: "2020-01-17T12:00:00Z"},
	})
	require.NoError(t, pushQueueHandleUpdates([]*repo_module.PushUpdateOptions{
		{
			RefFullName:  git.RefNameFromBranch("feature"),
			OldCommitID:  git.Sha1ObjectFormat.EmptyObjectID().String(),
			NewCommitID:  featureCommits["feature-pushed"],
			PusherID:     1,
			RepoUserName: repo.OwnerName,
			RepoName:     repo.Name,
		},
	}))
	assert.Empty(t, loadHeatmapContributionsForRepo(t, repo.ID))
}

type heatmapIndexTestCommit struct {
	Branch         string
	Mark           string
	Parent         string
	AuthorName     string
	AuthorEmail    string
	CommitterName  string
	CommitterEmail string
	AuthorDate     string
}

func prepareHeatmapIndexRepo(t *testing.T, repoName string, commits []heatmapIndexTestCommit) (*repo_model.Repository, map[string]string) {
	t.Helper()
	require.NoError(t, unittest.PrepareTestDatabase())
	require.NoError(t, db.TruncateBeans(t.Context(), &activities_model.HeatmapContribution{}))

	owner := unittest.AssertExistsAndLoadBean(t, &user_model.User{ID: 2})
	repo, err := CreateRepositoryDirectly(t.Context(), owner, owner, CreateRepoOptions{Name: repoName, DefaultBranch: "main"}, true)
	require.NoError(t, err)

	marks := runFastImport(t, repo, commits)
	repo.IsEmpty = false
	require.NoError(t, repo_model.UpdateRepositoryColsWithAutoTime(t.Context(), repo, "is_empty"))
	return repo, marks
}

func runFastImport(t *testing.T, repo *repo_model.Repository, commits []heatmapIndexTestCommit) map[string]string {
	t.Helper()

	var stream strings.Builder
	branchTips := make(map[string]string)
	for i, commit := range commits {
		mark := fmt.Sprintf(":%d", i+1)
		branchRef := "refs/heads/" + commit.Branch
		stream.WriteString("commit " + branchRef + "\n")
		stream.WriteString("mark " + mark + "\n")
		stream.WriteString(signatureLine("author", commit.AuthorName, commit.AuthorEmail, commit.AuthorDate))
		stream.WriteString(signatureLine("committer", commit.CommitterName, commit.CommitterEmail, commit.AuthorDate))
		message := "heatmap " + commit.Mark
		stream.WriteString(fmt.Sprintf("data %d\n%s\n", len(message), message))
		if parentMark := branchTips[commit.Branch]; parentMark != "" {
			stream.WriteString("from " + parentMark + "\n")
		} else if commit.Parent != "" {
			stream.WriteString("from " + commit.Parent + "\n")
		}
		content := commit.Mark + "\n"
		stream.WriteString(fmt.Sprintf("M 100644 inline %s.txt\n", commit.Mark))
		stream.WriteString(fmt.Sprintf("data %d\n%s", len(content), content))
		branchTips[commit.Branch] = mark
	}

	require.NoError(t, gitcmd.NewCommand("fast-import", "--export-marks=-").
		WithDir(repo.RepoPath()).
		WithStdinCopy(strings.NewReader(stream.String())).
		Run(t.Context()))

	commitSHAs := make(map[string]string, len(commits))
	for _, commit := range commits {
		stdout, _, err := gitcmd.NewCommand("log", "-1", "--format=%H", "--fixed-strings").
			AddOptionFormat("--grep=%s", "heatmap "+commit.Mark).
			AddDynamicArguments("refs/heads/" + commit.Branch).
			WithDir(repo.RepoPath()).
			RunStdString(t.Context())
		require.NoError(t, err)
		commitSHAs[commit.Mark] = strings.TrimSpace(stdout)
	}
	return commitSHAs
}

func signatureLine(kind, name, email, date string) string {
	parsed, err := time.Parse(time.RFC3339, date)
	if err != nil {
		panic(err)
	}
	return fmt.Sprintf("%s %s <%s> %d +0000\n", kind, name, email, parsed.Unix())
}

func loadHeatmapContributionsForRepo(t *testing.T, repoID int64) []*activities_model.HeatmapContribution {
	t.Helper()
	contributions, err := activities_model.FindHeatmapContributionsByRepo(t.Context(), repoID)
	require.NoError(t, err)
	return contributions
}

func deleteMainRef(t *testing.T, repo *repo_model.Repository) {
	t.Helper()
	require.NoError(t, gitcmd.NewCommand("update-ref", "-d", "refs/heads/main").WithDir(repo.RepoPath()).Run(t.Context()))
}
