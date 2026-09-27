// Copyright 2026 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package repo

import (
	"errors"
	"net/http"

	"gitea.dev/models/db"
	issues_model "gitea.dev/models/issues"
	project_model "gitea.dev/models/project"
	"gitea.dev/modules/optional"
	api "gitea.dev/modules/structs"
	"gitea.dev/modules/util"
	"gitea.dev/modules/web"
	"gitea.dev/routers/api/v1/utils"
	"gitea.dev/services/context"
	"gitea.dev/services/convert"
	project_service "gitea.dev/services/projects"
)

func getRepoProject(ctx *context.APIContext) *project_model.Project {
	project, err := project_model.GetProjectForRepoByID(ctx, ctx.Repo.Repository.ID, ctx.PathParamInt64("id"))
	if err != nil {
		if project_model.IsErrProjectNotExist(err) {
			ctx.APIErrorNotFound()
		} else {
			ctx.APIErrorInternal(err)
		}
		return nil
	}
	return project
}

func getProjectColumn(ctx *context.APIContext, projectID int64) *project_model.Column {
	column, err := project_model.GetColumnByIDAndProjectID(ctx, ctx.PathParamInt64("column_id"), projectID)
	if err != nil {
		if project_model.IsErrProjectColumnNotExist(err) {
			ctx.APIErrorNotFound()
		} else {
			ctx.APIErrorInternal(err)
		}
		return nil
	}
	return column
}

// ListProjects list a repository's projects
func ListProjects(ctx *context.APIContext) {
	// swagger:operation GET /repos/{owner}/{repo}/projects project repoListProjects
	// ---
	// summary: List a repository's projects
	// produces:
	// - application/json
	// parameters:
	// - name: owner
	//   in: path
	//   required: true
	//   type: string
	// - name: repo
	//   in: path
	//   required: true
	//   type: string
	// - name: state
	//   in: query
	//   type: string
	//   enum: [open, closed, all]
	//   default: open
	// - name: page
	//   in: query
	//   type: integer
	// - name: limit
	//   in: query
	//   type: integer
	// responses:
	//   "200":
	//     "$ref": "#/responses/ProjectList"
	//   "422":
	//     "$ref": "#/responses/validationError"
	//   "404":
	//     "$ref": "#/responses/notFound"
	//   "500":
	//     "$ref": "#/responses/internalServerError"

	state := ctx.FormString("state")
	isClosed := optional.Some(false)
	switch state {
	case "", "open":
	case "closed":
		isClosed = optional.Some(true)
	case "all":
		isClosed = optional.None[bool]()
	default:
		ctx.APIError(http.StatusUnprocessableEntity, "state must be one of open, closed, or all")
		return
	}

	listOptions := utils.GetListOptions(ctx)
	projects, count, err := db.FindAndCount[project_model.Project](ctx, project_model.SearchOptions{
		ListOptions: listOptions,
		RepoID:      ctx.Repo.Repository.ID,
		IsClosed:    isClosed,
		OrderBy:     db.SearchOrderByNewest,
		Type:        project_model.TypeRepository,
	})
	if err != nil {
		ctx.APIErrorInternal(err)
		return
	}
	ctx.SetLinkHeader(count, listOptions.PageSize)
	ctx.SetTotalCountHeader(count)
	ctx.JSON(http.StatusOK, convert.ToAPIProjectList(projects))
}

// ListProjectColumns list a repository project's columns
func ListProjectColumns(ctx *context.APIContext) {
	// swagger:operation GET /repos/{owner}/{repo}/projects/{id}/columns project repoListProjectColumns
	// ---
	// summary: List a repository project's columns
	// produces:
	// - application/json
	// parameters:
	// - name: owner
	//   in: path
	//   required: true
	//   type: string
	// - name: repo
	//   in: path
	//   required: true
	//   type: string
	// - name: id
	//   in: path
	//   required: true
	//   type: integer
	//   format: int64
	// responses:
	//   "200":
	//     "$ref": "#/responses/ProjectColumnList"
	//   "404":
	//     "$ref": "#/responses/notFound"
	//   "500":
	//     "$ref": "#/responses/internalServerError"

	project := getRepoProject(ctx)
	if project == nil {
		return
	}
	columns, err := project.GetColumns(ctx)
	if err != nil {
		ctx.APIErrorInternal(err)
		return
	}
	ctx.SetTotalCountHeader(int64(len(columns)))
	ctx.JSON(http.StatusOK, convert.ToAPIProjectColumnList(columns))
}

// ListProjectColumnIssues list issues in a repository project column
func ListProjectColumnIssues(ctx *context.APIContext) {
	// swagger:operation GET /repos/{owner}/{repo}/projects/{id}/columns/{column_id}/issues project repoListProjectColumnIssues
	// ---
	// summary: List issues in a repository project column
	// produces:
	// - application/json
	// parameters:
	// - name: owner
	//   in: path
	//   required: true
	//   type: string
	// - name: repo
	//   in: path
	//   required: true
	//   type: string
	// - name: id
	//   in: path
	//   required: true
	//   type: integer
	//   format: int64
	// - name: column_id
	//   in: path
	//   required: true
	//   type: integer
	//   format: int64
	// - name: page
	//   in: query
	//   type: integer
	// - name: limit
	//   in: query
	//   type: integer
	// responses:
	//   "200":
	//     "$ref": "#/responses/IssueList"
	//   "404":
	//     "$ref": "#/responses/notFound"
	//   "500":
	//     "$ref": "#/responses/internalServerError"

	project := getRepoProject(ctx)
	if project == nil {
		return
	}
	column := getProjectColumn(ctx, project.ID)
	if column == nil {
		return
	}
	listOptions := utils.GetListOptions(ctx)
	issueOptions := &issues_model.IssuesOptions{
		Paginator:                 &listOptions,
		RepoIDs:                   []int64{ctx.Repo.Repository.ID},
		ProjectIDs:                []int64{project.ID},
		ProjectColumnID:           column.ID,
		ProjectColumnOrUnassigned: column.Default,
		SortType:                  "project-column-sorting",
		Doer:                      ctx.Doer,
	}
	total, err := issues_model.CountIssues(ctx, issueOptions)
	if err != nil {
		ctx.APIErrorInternal(err)
		return
	}
	issues, err := issues_model.Issues(ctx, issueOptions)
	if err != nil {
		ctx.APIErrorInternal(err)
		return
	}
	ctx.SetLinkHeader(total, listOptions.PageSize)
	ctx.SetTotalCountHeader(total)
	ctx.JSON(http.StatusOK, convert.ToAPIIssueList(ctx, ctx.Doer, issues))
}

// MoveProjectIssue moves an issue to another repository project column
func MoveProjectIssue(ctx *context.APIContext) {
	// swagger:operation POST /repos/{owner}/{repo}/projects/{id}/issues/{issue_id}/move project repoMoveProjectIssue
	// ---
	// summary: Move an issue to another repository project column
	// consumes:
	// - application/json
	// parameters:
	// - name: owner
	//   in: path
	//   required: true
	//   type: string
	// - name: repo
	//   in: path
	//   required: true
	//   type: string
	// - name: id
	//   in: path
	//   required: true
	//   type: integer
	//   format: int64
	// - name: issue_id
	//   in: path
	//   required: true
	//   type: integer
	//   format: int64
	// - name: body
	//   in: body
	//   required: true
	//   schema:
	//     "$ref": "#/definitions/MoveProjectIssueOption"
	// responses:
	//   "204":
	//     description: issue moved
	//   "403":
	//     "$ref": "#/responses/forbidden"
	//   "423":
	//     "$ref": "#/responses/locked"
	//   "404":
	//     "$ref": "#/responses/notFound"
	//   "422":
	//     "$ref": "#/responses/validationError"
	//   "500":
	//     "$ref": "#/responses/internalServerError"

	project := getRepoProject(ctx)
	if project == nil {
		return
	}
	if project.IsClosed {
		ctx.APIError(http.StatusForbidden, "project is closed")
		return
	}
	form := web.GetForm(ctx).(*api.MoveProjectIssueOption)
	column, err := project_model.GetColumnByIDAndProjectID(ctx, form.ColumnID, project.ID)
	if err != nil {
		if project_model.IsErrProjectColumnNotExist(err) {
			ctx.APIErrorNotFound()
		} else {
			ctx.APIErrorInternal(err)
		}
		return
	}
	issueID := ctx.PathParamInt64("issue_id")
	if _, err := issues_model.GetIssueByRepoID(ctx, ctx.Repo.Repository.ID, issueID); err != nil {
		if issues_model.IsErrIssueNotExist(err) {
			ctx.APIErrorNotFound()
		} else {
			ctx.APIErrorInternal(err)
		}
		return
	}
	if err := project_service.MoveIssueOnProjectColumn(ctx, ctx.Doer, column, issueID, form.Sorting); err != nil {
		if errors.Is(err, util.ErrNotExist) {
			ctx.APIErrorNotFound()
		} else if errors.Is(err, util.ErrInvalidArgument) {
			ctx.APIError(http.StatusUnprocessableEntity, err.Error())
		} else {
			ctx.APIErrorInternal(err)
		}
		return
	}
	ctx.Status(http.StatusNoContent)
}
