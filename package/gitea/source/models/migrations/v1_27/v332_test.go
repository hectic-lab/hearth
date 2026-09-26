// Copyright 2026 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package v1_27

import (
	"testing"

	"gitea.dev/models/migrations/migrationtest"

	"github.com/stretchr/testify/require"
)

func TestBridgeHeatmapMigrationCollision(t *testing.T) {
	x, deferable := migrationtest.PrepareTestEnv(t, 0,
		new(actionRunBeforeV331),
		new(actionRunJobBeforeV331),
		new(actionArtifactBeforeV331),
		new(heatmapContribution),
		new(mirrorWithLastSyncUnix),
	)
	defer deferable()
	if x == nil || t.Failed() {
		return
	}

	require.NoError(t, BridgeHeatmapMigrationCollision(x))

	hasActionRunAttempt, err := x.IsTableExist(new(actionRunAttempt))
	require.NoError(t, err)
	require.True(t, hasActionRunAttempt)

	hasHeatmap, err := x.IsTableExist(new(heatmapContribution))
	require.NoError(t, err)
	require.True(t, hasHeatmap)

	mirrorTable, err := x.TableInfo(new(mirrorWithLastSyncUnix))
	require.NoError(t, err)
	require.NotNil(t, mirrorTable.GetColumn("last_sync_unix"))
}
