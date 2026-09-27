// Copyright 2026 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package swagger

import api "gitea.dev/modules/structs"

// ProjectList
// swagger:response ProjectList
type swaggerResponseProjectList struct {
	// in:body
	Body []api.Project `json:"body"`
}

// ProjectColumnList
// swagger:response ProjectColumnList
type swaggerResponseProjectColumnList struct {
	// in:body
	Body []api.ProjectColumn `json:"body"`
}
