// Copyright 2026 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package cmd

import (
	"context"
	"fmt"
	"strings"

	"gitea.dev/models/db"
	repo_model "gitea.dev/models/repo"
	"gitea.dev/modules/git"
	"gitea.dev/modules/log"
	repo_service "gitea.dev/services/repository"

	"github.com/urfave/cli/v3"
)

func newHeatmapCommand() *cli.Command {
	return &cli.Command{
		Name:  "heatmap",
		Usage: "Manage heatmap indexes",
		Commands: []*cli.Command{
			newHeatmapReindexCommand(),
		},
	}
}

func newHeatmapReindexCommand() *cli.Command {
	return &cli.Command{
		Name:   "reindex",
		Usage:  "Reindex heatmap contributions from repository default branches",
		Action: runHeatmapReindex,
		Flags: []cli.Flag{
			&cli.BoolFlag{
				Name:  "all",
				Usage: "Reindex all repositories",
			},
			&cli.StringFlag{
				Name:  "repo",
				Usage: "Repository to reindex as owner/name, or repository name when --owner is set",
			},
			&cli.StringFlag{
				Name:  "owner",
				Usage: "Owner name for --repo",
			},
		},
	}
}

func runHeatmapReindex(ctx context.Context, c *cli.Command) error {
	if err := initDB(ctx); err != nil {
		return err
	}
	if err := git.InitSimple(); err != nil {
		return err
	}

	reindexAll := c.Bool("all")
	repoName := c.String("repo")
	ownerName := c.String("owner")
	if reindexAll {
		if repoName != "" || ownerName != "" {
			return fmt.Errorf("--all cannot be combined with --repo or --owner")
		}
		return reindexAllHeatmapRepositories(ctx)
	}
	if repoName == "" {
		return fmt.Errorf("either --all or --repo must be provided")
	}

	ownerName, repoName, err := parseHeatmapRepoSelector(ownerName, repoName)
	if err != nil {
		return err
	}
	repo, err := repo_model.GetRepositoryByOwnerAndName(ctx, ownerName, repoName)
	if err != nil {
		return err
	}
	return reindexHeatmapRepository(ctx, repo)
}

func parseHeatmapRepoSelector(ownerName, repoName string) (string, string, error) {
	if ownerName != "" {
		if strings.Contains(repoName, "/") {
			return "", "", fmt.Errorf("--repo must be a repository name when --owner is set")
		}
		return ownerName, repoName, nil
	}

	ownerName, repoName, ok := strings.Cut(repoName, "/")
	if !ok || ownerName == "" || repoName == "" || strings.Contains(repoName, "/") {
		return "", "", fmt.Errorf("--repo must be provided as owner/name unless --owner is set")
	}
	return ownerName, repoName, nil
}

func reindexAllHeatmapRepositories(ctx context.Context) error {
	for page := 1; ; page++ {
		repos, count, err := repo_model.SearchRepositoryByName(ctx, repo_model.SearchRepoOptions{
			ListOptions: db.ListOptions{
				PageSize: repo_model.RepositoryListDefaultPageSize,
				Page:     page,
			},
			Private: true,
		})
		if err != nil {
			return fmt.Errorf("SearchRepositoryByName: %w", err)
		}
		if len(repos) == 0 {
			break
		}
		log.Trace("Processing next %d repos of %d", len(repos), count)
		for _, repo := range repos {
			if err := reindexHeatmapRepository(ctx, repo); err != nil {
				log.Warn("Reindexing heatmap contributions for repo %s failed: %v", repo.FullName(), err)
				continue
			}
		}
	}
	return nil
}

func reindexHeatmapRepository(ctx context.Context, repo *repo_model.Repository) error {
	log.Trace("Reindexing heatmap contributions for repo %s", repo.FullName())
	if err := repo_service.IndexDefaultBranchHeatmapContributions(ctx, repo); err != nil {
		return fmt.Errorf("IndexDefaultBranchHeatmapContributions[%s]: %w", repo.FullName(), err)
	}
	return nil
}
