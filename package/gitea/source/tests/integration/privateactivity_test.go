// Copyright 2020 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package integration

import (
	"fmt"
	"net/http"
	"testing"
	"time"

	activities_model "gitea.dev/models/activities"
	auth_model "gitea.dev/models/auth"
	"gitea.dev/models/db"
	repo_model "gitea.dev/models/repo"
	"gitea.dev/models/unittest"
	user_model "gitea.dev/models/user"
	api "gitea.dev/modules/structs"
	"gitea.dev/modules/timeutil"
	"gitea.dev/tests"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	privateActivityTestAdmin = "user1"
	privateActivityTestUser  = "user2"
)

const privateActivityHeatmapOptInUser = "user16"

// org3 is an organization so it is not usable here
const privateActivityTestOtherUser = "user4"

// activity helpers

func testPrivateActivityDoSomethingForActionEntries(t *testing.T) {
	repoBefore := unittest.AssertExistsAndLoadBean(t, &repo_model.Repository{ID: 1})
	owner := unittest.AssertExistsAndLoadBean(t, &user_model.User{ID: repoBefore.OwnerID})

	session := loginUser(t, privateActivityTestUser)
	token := getTokenForLoggedInUser(t, session, auth_model.AccessTokenScopeWriteIssue)
	urlStr := fmt.Sprintf("/api/v1/repos/%s/%s/issues?state=all", owner.Name, repoBefore.Name)
	req := NewRequestWithJSON(t, "POST", urlStr, &api.CreateIssueOption{
		Body:  "test",
		Title: "test",
	}).AddTokenAuth(token)
	session.MakeRequest(t, req, http.StatusCreated)
	testHeatmapSeedContribution(t, 2, 1, "private-activity-action-public", timeutil.TimeStampNow()-900)
}

// private activity helpers

func testPrivateActivityHelperEnablePrivateActivity(t *testing.T) {
	session := loginUser(t, privateActivityTestUser)
	req := NewRequestWithValues(t, "POST", "/user/settings", map[string]string{
		"name":                  privateActivityTestUser,
		"email":                 privateActivityTestUser + "@example.com",
		"language":              "en-US",
		"keep_activity_private": "1",
	})
	session.MakeRequest(t, req, http.StatusSeeOther)
}

func testPrivateActivityHelperSetIncludePrivateContributionsViaWeb(t *testing.T, session *TestSession, username string, include bool) {
	values := map[string]string{
		"name":     username,
		"email":    username + "@example.com",
		"language": "en-US",
	}
	if include {
		values["include_private_contributions"] = "1"
	}
	req := NewRequestWithValues(t, "POST", "/user/settings", values)
	session.MakeRequest(t, req, http.StatusSeeOther)
}

func testPrivateActivityHelperAssertIncludePrivateContributions(t *testing.T, username string, expected bool) {
	user := unittest.AssertExistsAndLoadBean(t, &user_model.User{Name: username})
	includePrivateContributions, err := user_model.GetIncludePrivateContributions(t.Context(), user.ID)
	require.NoError(t, err)
	assert.Equal(t, expected, includePrivateContributions)
}

func testPrivateActivityHelperHasVisibleActivitiesInHTMLDoc(htmlDoc *HTMLDoc) bool {
	return htmlDoc.doc.Find("#activity-feed").Find(".item").Length() > 0
}

func testPrivateActivityHelperHasVisibleActivitiesFromSession(t *testing.T, session *TestSession) bool {
	req := NewRequestf(t, "GET", "/%s?tab=activity", privateActivityTestUser)
	resp := session.MakeRequest(t, req, http.StatusOK)

	htmlDoc := NewHTMLParser(t, resp.Body)

	return testPrivateActivityHelperHasVisibleActivitiesInHTMLDoc(htmlDoc)
}

func testPrivateActivityHelperHasVisibleActivitiesFromPublic(t *testing.T) bool {
	req := NewRequestf(t, "GET", "/%s?tab=activity", privateActivityTestUser)
	resp := MakeRequest(t, req, http.StatusOK)

	htmlDoc := NewHTMLParser(t, resp.Body)

	return testPrivateActivityHelperHasVisibleActivitiesInHTMLDoc(htmlDoc)
}

// heatmap UI helpers

func testPrivateActivityHelperHasVisibleHeatmapInHTMLDoc(htmlDoc *HTMLDoc) bool {
	return htmlDoc.doc.Find("#user-heatmap").Length() > 0
}

func testPrivateActivityHelperHasVisibleProfileHeatmapFromSession(t *testing.T, session *TestSession) bool {
	req := NewRequestf(t, "GET", "/%s?tab=activity", privateActivityTestUser)
	resp := session.MakeRequest(t, req, http.StatusOK)

	htmlDoc := NewHTMLParser(t, resp.Body)

	return testPrivateActivityHelperHasVisibleHeatmapInHTMLDoc(htmlDoc)
}

func testPrivateActivityHelperHasVisibleDashboardHeatmapFromSession(t *testing.T, session *TestSession) bool {
	req := NewRequest(t, "GET", "/")
	resp := session.MakeRequest(t, req, http.StatusOK)

	htmlDoc := NewHTMLParser(t, resp.Body)

	return testPrivateActivityHelperHasVisibleHeatmapInHTMLDoc(htmlDoc)
}

func testPrivateActivityHelperHasVisibleHeatmapFromPublic(t *testing.T) bool {
	req := NewRequestf(t, "GET", "/%s?tab=activity", privateActivityTestUser)
	resp := MakeRequest(t, req, http.StatusOK)

	htmlDoc := NewHTMLParser(t, resp.Body)

	return testPrivateActivityHelperHasVisibleHeatmapInHTMLDoc(htmlDoc)
}

// heatmap API helpers

func testPrivateActivityHelperHasHeatmapContentFromPublic(t *testing.T) bool {
	req := NewRequestf(t, "GET", "/api/v1/users/%s/heatmap", privateActivityTestUser)
	resp := MakeRequest(t, req, http.StatusOK)

	items := DecodeJSON(t, resp, []*activities_model.UserHeatmapData{})

	return len(items) != 0
}

func testPrivateActivityHelperHasHeatmapContentFromSession(t *testing.T, session *TestSession) bool {
	token := getTokenForLoggedInUser(t, session, auth_model.AccessTokenScopeReadUser)

	req := NewRequestf(t, "GET", "/api/v1/users/%s/heatmap", privateActivityTestUser).
		AddTokenAuth(token)
	resp := session.MakeRequest(t, req, http.StatusOK)

	items := DecodeJSON(t, resp, []*activities_model.UserHeatmapData{})

	return len(items) != 0
}

func testPrivateActivityHelperGetAPIHeatmapFromPublic(t *testing.T) ([]*activities_model.UserHeatmapData, []byte) {
	req := NewRequestf(t, "GET", "/api/v1/users/%s/heatmap", privateActivityHeatmapOptInUser)
	resp := MakeRequest(t, req, http.StatusOK)
	body := resp.Body.Bytes()

	var items []*activities_model.UserHeatmapData
	DecodeJSON(t, resp, &items)

	return items, body
}

func testPrivateActivityHelperGetAPIHeatmapFromSession(t *testing.T, session *TestSession) ([]*activities_model.UserHeatmapData, []byte) {
	token := getTokenForLoggedInUser(t, session, auth_model.AccessTokenScopeReadUser)

	req := NewRequestf(t, "GET", "/api/v1/users/%s/heatmap", privateActivityHeatmapOptInUser).
		AddTokenAuth(token)
	resp := session.MakeRequest(t, req, http.StatusOK)
	body := resp.Body.Bytes()

	var items []*activities_model.UserHeatmapData
	DecodeJSON(t, resp, &items)

	return items, body
}

func testPrivateActivityHelperGetWebHeatmapFromPublic(t *testing.T) (testHeatmapWebResponse, []byte) {
	req := NewRequestf(t, "GET", "/%s/-/heatmap", privateActivityHeatmapOptInUser)
	resp := MakeRequest(t, req, http.StatusOK)
	body := resp.Body.Bytes()

	return testHeatmapDecodeWebResponse(t, resp), body
}

func testPrivateActivityHelperSeedHeatmapContributions(t *testing.T) string {
	t.Helper()

	require.NoError(t, db.TruncateBeans(t.Context(), &activities_model.HeatmapContribution{}))
	require.NoError(t, user_model.SetIncludePrivateContributions(t.Context(), 16, false))

	testHeatmapSeedContribution(t, 16, 21, "private-activity-public", 1603009800)
	privateSHA := testHeatmapSeedContribution(t, 16, 22, "private-activity-private-one", 1603009850)
	testHeatmapSeedContribution(t, 16, 22, "private-activity-private-two", 1603010700)

	return privateSHA
}

func testPrivateActivityHelperAssertAPIHeatmapTotal(t *testing.T, heatmap []*activities_model.UserHeatmapData, expected int64) {
	t.Helper()

	assert.Equal(t, expected, testHeatmapSumAPIContributions(heatmap))
}

// check private contribution opt-in settings persistence and ownership

func TestPrivateActivityIncludePrivateContributionsWebSettingsPersistence(t *testing.T) {
	defer tests.PrepareTestEnv(t)()

	session := loginUser(t, privateActivityTestUser)
	testPrivateActivityHelperAssertIncludePrivateContributions(t, privateActivityTestUser, false)

	testPrivateActivityHelperSetIncludePrivateContributionsViaWeb(t, session, privateActivityTestUser, true)
	testPrivateActivityHelperAssertIncludePrivateContributions(t, privateActivityTestUser, true)
	user := unittest.AssertExistsAndLoadBean(t, &user_model.User{Name: privateActivityTestUser})
	assert.False(t, user.KeepActivityPrivate, "private contribution opt-in must not hide the whole activity heatmap")

	req := NewRequest(t, "GET", "/user/settings")
	resp := session.MakeRequest(t, req, http.StatusOK)
	htmlDoc := NewHTMLParser(t, resp.Body)
	assert.Equal(t, 1, htmlDoc.doc.Find("#include-private-contributions input[name='include_private_contributions']:checked").Length())

	testPrivateActivityHelperSetIncludePrivateContributionsViaWeb(t, session, privateActivityTestUser, false)
	testPrivateActivityHelperAssertIncludePrivateContributions(t, privateActivityTestUser, false)
}

func TestPrivateActivityIncludePrivateContributionsAPISettingsPersistence(t *testing.T) {
	defer tests.PrepareTestEnv(t)()

	session := loginUser(t, privateActivityTestUser)
	token := getTokenForLoggedInUser(t, session, auth_model.AccessTokenScopeReadUser, auth_model.AccessTokenScopeWriteUser)

	includePrivateContributions := true
	req := NewRequestWithJSON(t, "PATCH", "/api/v1/user/settings", &api.UserSettingsOptions{
		IncludePrivateContributions: &includePrivateContributions,
	}).AddTokenAuth(token)
	resp := session.MakeRequest(t, req, http.StatusOK)
	settings := DecodeJSON(t, resp, &api.UserSettings{})
	assert.True(t, settings.IncludePrivateContributions)
	testPrivateActivityHelperAssertIncludePrivateContributions(t, privateActivityTestUser, true)
	user := unittest.AssertExistsAndLoadBean(t, &user_model.User{Name: privateActivityTestUser})
	assert.False(t, user.KeepActivityPrivate, "API opt-in must not set KeepActivityPrivate")

	req = NewRequest(t, "GET", "/api/v1/user/settings").AddTokenAuth(token)
	resp = session.MakeRequest(t, req, http.StatusOK)
	settings = DecodeJSON(t, resp, &api.UserSettings{})
	assert.True(t, settings.IncludePrivateContributions)

	includePrivateContributions = false
	req = NewRequestWithJSON(t, "PATCH", "/api/v1/user/settings", &api.UserSettingsOptions{
		IncludePrivateContributions: &includePrivateContributions,
	}).AddTokenAuth(token)
	resp = session.MakeRequest(t, req, http.StatusOK)
	settings = DecodeJSON(t, resp, &api.UserSettings{})
	assert.False(t, settings.IncludePrivateContributions)
	testPrivateActivityHelperAssertIncludePrivateContributions(t, privateActivityTestUser, false)
}

func TestPrivateActivityPrivateContributionsHiddenByDefault(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	timeutil.MockSet(time.Date(2021, 1, 1, 0, 0, 0, 0, time.UTC))
	defer timeutil.MockUnset()
	testPrivateActivityHelperSeedHeatmapContributions(t)

	publicHeatmap, _ := testPrivateActivityHelperGetAPIHeatmapFromPublic(t)
	testPrivateActivityHelperAssertAPIHeatmapTotal(t, publicHeatmap, 1)

	for _, testCase := range []struct {
		name     string
		username string
	}{
		{"owner", privateActivityHeatmapOptInUser},
		{"admin", privateActivityTestAdmin},
		{"collaborator", "user15"},
		{"unrelated", privateActivityTestOtherUser},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			session := loginUser(t, testCase.username)
			heatmap, _ := testPrivateActivityHelperGetAPIHeatmapFromSession(t, session)
			testPrivateActivityHelperAssertAPIHeatmapTotal(t, heatmap, 1)
		})
	}
}

func TestPrivateActivityIncludePrivateContributionsEndpointAggregatesOnly(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	timeutil.MockSet(time.Date(2021, 1, 1, 0, 0, 0, 0, time.UTC))
	defer timeutil.MockUnset()
	privateSHA := testPrivateActivityHelperSeedHeatmapContributions(t)

	ownerSession := loginUser(t, privateActivityHeatmapOptInUser)
	testPrivateActivityHelperSetIncludePrivateContributionsViaWeb(t, ownerSession, privateActivityHeatmapOptInUser, true)

	apiHeatmap, apiBody := testPrivateActivityHelperGetAPIHeatmapFromPublic(t)
	testPrivateActivityHelperAssertAPIHeatmapTotal(t, apiHeatmap, 3)
	testHeatmapAssertAggregateOnlyAPIResponse(t, apiBody)
	testHeatmapAssertNoPrivateMetadata(t, apiBody,
		"big_test_private_3",
		"22",
		privateSHA,
		"private-activity-private-one",
		"master",
		"/user16/big_test_private_3",
	)

	webHeatmap, webBody := testPrivateActivityHelperGetWebHeatmapFromPublic(t)
	assert.Equal(t, int64(3), webHeatmap.TotalContributions)
	testHeatmapAssertAggregateOnlyWebResponse(t, webBody)
	testHeatmapAssertNoPrivateMetadata(t, webBody,
		"big_test_private_3",
		"22",
		privateSHA,
		"private-activity-private-one",
		"master",
		"/user16/big_test_private_3",
	)

	testPrivateActivityHelperSetIncludePrivateContributionsViaWeb(t, ownerSession, privateActivityHeatmapOptInUser, false)
	apiHeatmap, _ = testPrivateActivityHelperGetAPIHeatmapFromPublic(t)
	testPrivateActivityHelperAssertAPIHeatmapTotal(t, apiHeatmap, 1)
}

func TestPrivateActivityIncludePrivateContributionsWebSettingsAuthBoundary(t *testing.T) {
	defer tests.PrepareTestEnv(t)()

	testPrivateActivityHelperAssertIncludePrivateContributions(t, privateActivityTestUser, false)

	otherSession := loginUser(t, privateActivityTestOtherUser)
	testPrivateActivityHelperSetIncludePrivateContributionsViaWeb(t, otherSession, privateActivityTestOtherUser, true)
	testPrivateActivityHelperAssertIncludePrivateContributions(t, privateActivityTestOtherUser, true)
	testPrivateActivityHelperAssertIncludePrivateContributions(t, privateActivityTestUser, false)

	req := NewRequestWithValues(t, "POST", "/user/settings", map[string]string{
		"name":                          privateActivityTestUser,
		"email":                         privateActivityTestUser + "@example.com",
		"language":                      "en-US",
		"include_private_contributions": "1",
	})
	MakeRequest(t, req, http.StatusSeeOther)
	testPrivateActivityHelperAssertIncludePrivateContributions(t, privateActivityTestUser, false)
}

// check activity visibility if the visibility is enabled

func TestPrivateActivityNoVisibleForPublic(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)

	visible := testPrivateActivityHelperHasVisibleActivitiesFromPublic(t)

	assert.True(t, visible, "user should have visible activities")
}

func TestPrivateActivityNoVisibleForUserItself(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)

	session := loginUser(t, privateActivityTestUser)
	visible := testPrivateActivityHelperHasVisibleActivitiesFromSession(t, session)

	assert.True(t, visible, "user should have visible activities")
}

func TestPrivateActivityNoVisibleForOtherUser(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)

	session := loginUser(t, privateActivityTestOtherUser)
	visible := testPrivateActivityHelperHasVisibleActivitiesFromSession(t, session)

	assert.True(t, visible, "user should have visible activities")
}

func TestPrivateActivityNoVisibleForAdmin(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)

	session := loginUser(t, privateActivityTestAdmin)
	visible := testPrivateActivityHelperHasVisibleActivitiesFromSession(t, session)

	assert.True(t, visible, "user should have visible activities")
}

// check activity visibility if the visibility is disabled

func TestPrivateActivityYesInvisibleForPublic(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)
	testPrivateActivityHelperEnablePrivateActivity(t)

	visible := testPrivateActivityHelperHasVisibleActivitiesFromPublic(t)

	assert.False(t, visible, "user should have no visible activities")
}

func TestPrivateActivityYesVisibleForUserItself(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)
	testPrivateActivityHelperEnablePrivateActivity(t)

	session := loginUser(t, privateActivityTestUser)
	visible := testPrivateActivityHelperHasVisibleActivitiesFromSession(t, session)

	assert.True(t, visible, "user should have visible activities")
}

func TestPrivateActivityYesInvisibleForOtherUser(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)
	testPrivateActivityHelperEnablePrivateActivity(t)

	session := loginUser(t, privateActivityTestOtherUser)
	visible := testPrivateActivityHelperHasVisibleActivitiesFromSession(t, session)

	assert.False(t, visible, "user should have no visible activities")
}

func TestPrivateActivityYesVisibleForAdmin(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)
	testPrivateActivityHelperEnablePrivateActivity(t)

	session := loginUser(t, privateActivityTestAdmin)
	visible := testPrivateActivityHelperHasVisibleActivitiesFromSession(t, session)

	assert.True(t, visible, "user should have visible activities")
}

// check heatmap visibility if the visibility is enabled

func TestPrivateActivityNoHeatmapVisibleForPublic(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)

	visible := testPrivateActivityHelperHasVisibleHeatmapFromPublic(t)

	assert.True(t, visible, "user should have visible heatmap")
}

func TestPrivateActivityNoHeatmapVisibleForUserItselfAtProfile(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)

	session := loginUser(t, privateActivityTestUser)
	visible := testPrivateActivityHelperHasVisibleProfileHeatmapFromSession(t, session)

	assert.True(t, visible, "user should have visible heatmap")
}

func TestPrivateActivityNoHeatmapVisibleForUserItselfAtDashboard(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)

	session := loginUser(t, privateActivityTestUser)
	visible := testPrivateActivityHelperHasVisibleDashboardHeatmapFromSession(t, session)

	assert.True(t, visible, "user should have visible heatmap")
}

func TestPrivateActivityNoHeatmapVisibleForOtherUser(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)

	session := loginUser(t, privateActivityTestOtherUser)
	visible := testPrivateActivityHelperHasVisibleProfileHeatmapFromSession(t, session)

	assert.True(t, visible, "user should have visible heatmap")
}

func TestPrivateActivityNoHeatmapVisibleForAdmin(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)

	session := loginUser(t, privateActivityTestAdmin)
	visible := testPrivateActivityHelperHasVisibleProfileHeatmapFromSession(t, session)

	assert.True(t, visible, "user should have visible heatmap")
}

// check heatmap visibility if the visibility is disabled

func TestPrivateActivityYesHeatmapInvisibleForPublic(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)
	testPrivateActivityHelperEnablePrivateActivity(t)

	visible := testPrivateActivityHelperHasVisibleHeatmapFromPublic(t)

	assert.False(t, visible, "user should have no visible heatmap")
}

func TestPrivateActivityYesHeatmapVisibleForUserItselfAtProfile(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)
	testPrivateActivityHelperEnablePrivateActivity(t)

	session := loginUser(t, privateActivityTestUser)
	visible := testPrivateActivityHelperHasVisibleProfileHeatmapFromSession(t, session)

	assert.True(t, visible, "user should have visible heatmap")
}

func TestPrivateActivityYesHeatmapVisibleForUserItselfAtDashboard(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)
	testPrivateActivityHelperEnablePrivateActivity(t)

	session := loginUser(t, privateActivityTestUser)
	visible := testPrivateActivityHelperHasVisibleDashboardHeatmapFromSession(t, session)

	assert.True(t, visible, "user should have visible heatmap")
}

func TestPrivateActivityYesHeatmapInvisibleForOtherUser(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)
	testPrivateActivityHelperEnablePrivateActivity(t)

	session := loginUser(t, privateActivityTestOtherUser)
	visible := testPrivateActivityHelperHasVisibleProfileHeatmapFromSession(t, session)

	assert.False(t, visible, "user should have no visible heatmap")
}

func TestPrivateActivityYesHeatmapVisibleForAdmin(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)
	testPrivateActivityHelperEnablePrivateActivity(t)

	session := loginUser(t, privateActivityTestAdmin)
	visible := testPrivateActivityHelperHasVisibleProfileHeatmapFromSession(t, session)

	assert.True(t, visible, "user should have visible heatmap")
}

// check heatmap api provides content if the visibility is enabled

func TestPrivateActivityNoHeatmapHasContentForPublic(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)

	hasContent := testPrivateActivityHelperHasHeatmapContentFromPublic(t)

	assert.True(t, hasContent, "user should have heatmap content")
}

func TestPrivateActivityNoHeatmapHasContentForUserItself(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)

	session := loginUser(t, privateActivityTestUser)
	hasContent := testPrivateActivityHelperHasHeatmapContentFromSession(t, session)

	assert.True(t, hasContent, "user should have heatmap content")
}

func TestPrivateActivityNoHeatmapHasContentForOtherUser(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)

	session := loginUser(t, privateActivityTestOtherUser)
	hasContent := testPrivateActivityHelperHasHeatmapContentFromSession(t, session)

	assert.True(t, hasContent, "user should have heatmap content")
}

func TestPrivateActivityNoHeatmapHasContentForAdmin(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)

	session := loginUser(t, privateActivityTestAdmin)
	hasContent := testPrivateActivityHelperHasHeatmapContentFromSession(t, session)

	assert.True(t, hasContent, "user should have heatmap content")
}

// check heatmap api provides no content if the visibility is disabled
// this should be equal to the hidden heatmap at the UI

func TestPrivateActivityYesHeatmapHasNoContentForPublic(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)
	testPrivateActivityHelperEnablePrivateActivity(t)

	hasContent := testPrivateActivityHelperHasHeatmapContentFromPublic(t)

	assert.False(t, hasContent, "user should have no heatmap content")
}

func TestPrivateActivityYesHeatmapHasNoContentForUserItself(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)
	testPrivateActivityHelperEnablePrivateActivity(t)

	session := loginUser(t, privateActivityTestUser)
	hasContent := testPrivateActivityHelperHasHeatmapContentFromSession(t, session)

	assert.True(t, hasContent, "user should see their own heatmap content")
}

func TestPrivateActivityYesHeatmapHasNoContentForOtherUser(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)
	testPrivateActivityHelperEnablePrivateActivity(t)

	session := loginUser(t, privateActivityTestOtherUser)
	hasContent := testPrivateActivityHelperHasHeatmapContentFromSession(t, session)

	assert.False(t, hasContent, "other user should not see heatmap content")
}

func TestPrivateActivityYesHeatmapHasNoContentForAdmin(t *testing.T) {
	defer tests.PrepareTestEnv(t)()
	testPrivateActivityDoSomethingForActionEntries(t)
	testPrivateActivityHelperEnablePrivateActivity(t)

	session := loginUser(t, privateActivityTestAdmin)
	hasContent := testPrivateActivityHelperHasHeatmapContentFromSession(t, session)

	assert.True(t, hasContent, "heatmap should show content for admin")
}
