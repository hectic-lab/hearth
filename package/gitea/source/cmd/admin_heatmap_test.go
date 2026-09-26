// Copyright 2026 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package cmd

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
	"gitea.dev/modules/git/gitcmd"
	"gitea.dev/modules/timeutil"
	repo_service "gitea.dev/services/repository"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestHeatmapAdminReindex(t *testing.T) {
	repo, commits := prepareHeatmapAdminRepo(t, "heatmap-admin-reindex", []heatmapAdminTestCommit{
		{Branch: "main", Mark: "initial", AuthorName: "User Two", AuthorEmail: "user2@example.com", CommitterName: "User One", CommitterEmail: "user1@example.com", AuthorDate: "2020-01-15T12:00:00Z"},
	})

	timeutil.MockSet(time.Date(2026, 6, 6, 0, 0, 0, 0, time.UTC))
	defer timeutil.MockUnset()

	require.NoError(t, reindexHeatmapRepository(t.Context(), repo))
	require.NoError(t, reindexHeatmapRepository(t.Context(), repo))
	contributions := loadHeatmapAdminContributionsForRepo(t, repo.ID)
	require.Len(t, contributions, 1)
	assert.Equal(t, commits["initial"], contributions[0].CommitSHA)

	require.NoError(t, gitcmd.NewCommand("update-ref", "-d", "refs/heads/main").WithDir(repo.RepoPath()).Run(t.Context()))
	newCommits := runHeatmapAdminFastImport(t, repo, []heatmapAdminTestCommit{
		{Branch: "main", Mark: "forced", AuthorName: "User Two", AuthorEmail: "user2@example.com", CommitterName: "User One", CommitterEmail: "user1@example.com", AuthorDate: "2020-01-16T12:00:00Z"},
	})
	require.NoError(t, reindexHeatmapRepository(t.Context(), repo))
	contributions = loadHeatmapAdminContributionsForRepo(t, repo.ID)
	require.Len(t, contributions, 1)
	assert.Equal(t, newCommits["forced"], contributions[0].CommitSHA)

	require.NoError(t, db.TruncateBeans(t.Context(), &activities_model.HeatmapContribution{}))
	require.NoError(t, reindexAllHeatmapRepositories(t.Context()))
	contributions = loadHeatmapAdminContributionsForRepo(t, repo.ID)
	require.Len(t, contributions, 1)
	assert.Equal(t, newCommits["forced"], contributions[0].CommitSHA)
}

func TestHeatmapAdminRepoSelector(t *testing.T) {
	owner, repo, err := parseHeatmapRepoSelector("", "user/repo")
	require.NoError(t, err)
	assert.Equal(t, "user", owner)
	assert.Equal(t, "repo", repo)

	owner, repo, err = parseHeatmapRepoSelector("user", "repo")
	require.NoError(t, err)
	assert.Equal(t, "user", owner)
	assert.Equal(t, "repo", repo)

	_, _, err = parseHeatmapRepoSelector("", "repo")
	assert.ErrorContains(t, err, "owner/name")
	_, _, err = parseHeatmapRepoSelector("user", "owner/repo")
	assert.ErrorContains(t, err, "when --owner is set")
}

type heatmapAdminTestCommit struct {
	Branch         string
	Mark           string
	Parent         string
	AuthorName     string
	AuthorEmail    string
	CommitterName  string
	CommitterEmail string
	AuthorDate     string
}

func prepareHeatmapAdminRepo(t *testing.T, repoName string, commits []heatmapAdminTestCommit) (*repo_model.Repository, map[string]string) {
	t.Helper()
	require.NoError(t, unittest.PrepareTestDatabase())
	require.NoError(t, db.TruncateBeans(t.Context(), &activities_model.HeatmapContribution{}))

	owner := unittest.AssertExistsAndLoadBean(t, &user_model.User{ID: 2})
	repo, err := repo_service.CreateRepositoryDirectly(t.Context(), owner, owner, repo_service.CreateRepoOptions{Name: repoName, DefaultBranch: "main"}, true)
	require.NoError(t, err)

	marks := runHeatmapAdminFastImport(t, repo, commits)
	repo.IsEmpty = false
	require.NoError(t, repo_model.UpdateRepositoryColsWithAutoTime(t.Context(), repo, "is_empty"))
	return repo, marks
}

func runHeatmapAdminFastImport(t *testing.T, repo *repo_model.Repository, commits []heatmapAdminTestCommit) map[string]string {
	t.Helper()

	var stream strings.Builder
	branchTips := make(map[string]string)
	for i, commit := range commits {
		mark := fmt.Sprintf(":%d", i+1)
		branchRef := "refs/heads/" + commit.Branch
		stream.WriteString("commit " + branchRef + "\n")
		stream.WriteString("mark " + mark + "\n")
		stream.WriteString(heatmapAdminSignatureLine("author", commit.AuthorName, commit.AuthorEmail, commit.AuthorDate))
		stream.WriteString(heatmapAdminSignatureLine("committer", commit.CommitterName, commit.CommitterEmail, commit.AuthorDate))
		message := "heatmap admin " + commit.Mark
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
			AddOptionFormat("--grep=%s", "heatmap admin "+commit.Mark).
			AddDynamicArguments("refs/heads/" + commit.Branch).
			WithDir(repo.RepoPath()).
			RunStdString(t.Context())
		require.NoError(t, err)
		commitSHAs[commit.Mark] = strings.TrimSpace(stdout)
	}
	return commitSHAs
}

func heatmapAdminSignatureLine(kind, name, email, date string) string {
	parsed, err := time.Parse(time.RFC3339, date)
	if err != nil {
		panic(err)
	}
	return fmt.Sprintf("%s %s <%s> %d +0000\n", kind, name, email, parsed.Unix())
}

func loadHeatmapAdminContributionsForRepo(t *testing.T, repoID int64) []*activities_model.HeatmapContribution {
	t.Helper()
	contributions, err := activities_model.FindHeatmapContributionsByRepo(t.Context(), repoID)
	require.NoError(t, err)
	return contributions
}
