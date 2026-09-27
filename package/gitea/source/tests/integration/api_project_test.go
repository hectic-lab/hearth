// Copyright 2026 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package integration

import (
	"fmt"
	"math"
	"net/http"
	"testing"

	auth_model "gitea.dev/models/auth"
	"gitea.dev/models/db"
	project_model "gitea.dev/models/project"
	repo_model "gitea.dev/models/repo"
	"gitea.dev/models/unittest"
	api "gitea.dev/modules/structs"
	"gitea.dev/tests"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAPIRepositoryProjects(t *testing.T) {
	defer tests.PrepareTestEnv(t)()

	repo := unittest.AssertExistsAndLoadBean(t, &repo_model.Repository{ID: 1})
	ownerSession := loginUser(t, repo.OwnerName)
	readToken := getTokenForLoggedInUser(t, ownerSession, auth_model.AccessTokenScopeReadIssue)
	writeToken := getTokenForLoggedInUser(t, ownerSession, auth_model.AccessTokenScopeWriteIssue)
	baseURL := fmt.Sprintf("/api/v1/repos/%s/projects", repo.FullName())

	t.Run("List", func(t *testing.T) {
		req := NewRequest(t, "GET", baseURL).AddTokenAuth(readToken)
		resp := MakeRequest(t, req, http.StatusOK)
		projects := DecodeJSON(t, resp, &[]api.Project{})
		require.Len(t, *projects, 1)
		assert.Equal(t, int64(1), (*projects)[0].ID)
		assert.Equal(t, "First project", (*projects)[0].Title)
	})

	t.Run("Columns", func(t *testing.T) {
		req := NewRequest(t, "GET", baseURL+"/1/columns").AddTokenAuth(readToken)
		resp := MakeRequest(t, req, http.StatusOK)
		columns := DecodeJSON(t, resp, &[]api.ProjectColumn{})
		require.Len(t, *columns, 3)
		assert.Equal(t, int64(1), (*columns)[0].ID)
		assert.Equal(t, "To Do", (*columns)[0].Title)
	})

	t.Run("ColumnIssues", func(t *testing.T) {
		req := NewRequest(t, "GET", baseURL+"/1/columns/2/issues").AddTokenAuth(readToken)
		resp := MakeRequest(t, req, http.StatusOK)
		issues := DecodeJSON(t, resp, &[]api.Issue{})
		require.Len(t, *issues, 1)
		assert.Equal(t, int64(3), (*issues)[0].ID)
	})

	t.Run("ColumnIssuesPaginationAndDefault", func(t *testing.T) {
		req := NewRequest(t, "GET", baseURL+"/1/columns/1/issues?limit=1&page=1").AddTokenAuth(readToken)
		resp := MakeRequest(t, req, http.StatusOK)
		issues := DecodeJSON(t, resp, &[]api.Issue{})
		require.Len(t, *issues, 1)
		assert.Equal(t, "2", resp.Header().Get("X-Total-Count"))

		req = NewRequest(t, "GET", baseURL+"/1/columns/1/issues?limit=1&page=2").AddTokenAuth(readToken)
		resp = MakeRequest(t, req, http.StatusOK)
		issues = DecodeJSON(t, resp, &[]api.Issue{})
		require.Len(t, *issues, 1)
		assert.NotEqual(t, (*issues)[0].ID, int64(0))
	})

	t.Run("CrossRepositoryProject", func(t *testing.T) {
		req := NewRequest(t, "GET", baseURL+"/2/columns").AddTokenAuth(readToken)
		MakeRequest(t, req, http.StatusNotFound)
	})

	t.Run("CrossProjectColumn", func(t *testing.T) {
		req := NewRequest(t, "GET", baseURL+"/1/columns/5/issues").AddTokenAuth(readToken)
		MakeRequest(t, req, http.StatusNotFound)
	})

	t.Run("RejectsSortingOverflow", func(t *testing.T) {
		projectIssue := unittest.AssertExistsAndLoadBean(t, &project_model.ProjectIssue{ProjectID: 1, IssueID: 3})
		sorting := int64(math.MaxInt64)
		req := NewRequestWithJSON(t, "POST", baseURL+"/1/issues/3/move", api.MoveProjectIssueOption{
			ColumnID: 3,
			Sorting:  &sorting,
		}).AddTokenAuth(writeToken)
		MakeRequest(t, req, http.StatusUnprocessableEntity)
		unchanged := unittest.AssertExistsAndLoadBean(t, &project_model.ProjectIssue{ProjectID: 1, IssueID: 3})
		assert.Equal(t, projectIssue.ProjectColumnID, unchanged.ProjectColumnID)
		assert.Equal(t, projectIssue.Sorting, unchanged.Sorting)
	})

	t.Run("ReordersWithinColumn", func(t *testing.T) {
		sorting := int64(0)
		req := NewRequestWithJSON(t, "POST", baseURL+"/1/issues/3/move", api.MoveProjectIssueOption{
			ColumnID: 1,
			Sorting:  &sorting,
		}).AddTokenAuth(writeToken)
		MakeRequest(t, req, http.StatusNoContent)

		sorting = 2
		req = NewRequestWithJSON(t, "POST", baseURL+"/1/issues/3/move", api.MoveProjectIssueOption{
			ColumnID: 1,
			Sorting:  &sorting,
		}).AddTokenAuth(writeToken)
		MakeRequest(t, req, http.StatusNoContent)

		var projectIssues []project_model.ProjectIssue
		err := db.GetEngine(t.Context()).
			Where("project_id=? AND project_board_id=?", 1, 1).
			OrderBy("sorting").Find(&projectIssues)
		require.NoError(t, err)
		require.Len(t, projectIssues, 2)
		assert.Equal(t, int64(3), projectIssues[1].IssueID)
		assert.Equal(t, []int64{0, 1}, []int64{projectIssues[0].Sorting, projectIssues[1].Sorting})
	})

	t.Run("Move", func(t *testing.T) {
		req := NewRequestWithJSON(t, "POST", baseURL+"/1/issues/3/move", api.MoveProjectIssueOption{
			ColumnID: 3,
		}).AddTokenAuth(writeToken)
		MakeRequest(t, req, http.StatusNoContent)
		projectIssue := unittest.AssertExistsAndLoadBean(t, &project_model.ProjectIssue{ProjectID: 1, IssueID: 3})
		assert.Equal(t, int64(3), projectIssue.ProjectColumnID)
	})

	t.Run("UnassignedIssue", func(t *testing.T) {
		req := NewRequestWithJSON(t, "POST", baseURL+"/1/issues/11/move", api.MoveProjectIssueOption{
			ColumnID: 3,
		}).AddTokenAuth(writeToken)
		MakeRequest(t, req, http.StatusUnprocessableEntity)
	})

	t.Run("Permission", func(t *testing.T) {
		outsiderSession := loginUser(t, "user5")
		outsiderToken := getTokenForLoggedInUser(t, outsiderSession, auth_model.AccessTokenScopeWriteIssue)
		req := NewRequestWithJSON(t, "POST", baseURL+"/1/issues/3/move", api.MoveProjectIssueOption{
			ColumnID: 2,
		}).AddTokenAuth(outsiderToken)
		MakeRequest(t, req, http.StatusForbidden)
	})

	t.Run("ClosedProject", func(t *testing.T) {
		project := unittest.AssertExistsAndLoadBean(t, &project_model.Project{ID: 1})
		require.NoError(t, project_model.ChangeProjectStatus(t.Context(), project, true))
		defer func() {
			require.NoError(t, project_model.ChangeProjectStatus(t.Context(), project, false))
		}()
		req := NewRequestWithJSON(t, "POST", baseURL+"/1/issues/3/move", api.MoveProjectIssueOption{
			ColumnID: 2,
		}).AddTokenAuth(writeToken)
		MakeRequest(t, req, http.StatusForbidden)
	})

	t.Run("ArchivedRepository", func(t *testing.T) {
		_, err := db.GetEngine(t.Context()).ID(repo.ID).Cols("is_archived").Update(&repo_model.Repository{IsArchived: true})
		require.NoError(t, err)
		defer func() {
			_, err := db.GetEngine(t.Context()).ID(repo.ID).Cols("is_archived").Update(&repo_model.Repository{IsArchived: false})
			require.NoError(t, err)
		}()
		req := NewRequestWithJSON(t, "POST", baseURL+"/1/issues/3/move", api.MoveProjectIssueOption{
			ColumnID: 2,
		}).AddTokenAuth(writeToken)
		MakeRequest(t, req, http.StatusLocked)
	})

	t.Run("DisabledProjects", func(t *testing.T) {
		disabledSession := loginUser(t, "user5")
		disabledToken := getTokenForLoggedInUser(t, disabledSession, auth_model.AccessTokenScopeReadIssue)
		req := NewRequest(t, "GET", "/api/v1/repos/user5/repo4/projects").AddTokenAuth(disabledToken)
		MakeRequest(t, req, http.StatusNotFound)
	})
}
