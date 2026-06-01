let
    // ============================
    // 1) CONFIG
    // ============================
    Host    = "https://github.kp.org",
    ApiRoot = "api/v3",

    // Golden PR marker: Sonatype IQ-for-SCM embeds this image in the body of every golden PR
    // (it appears once per bumped component, before each "AutoPR: Bump" / "PR: Bump" heading).
    // Matching the FILENAME only (not the full versioned CDN path /iq-for-scm/1.0/...) keeps this
    // stable across CDN version bumps and unifies both naming conventions in a single check.
    GoldenMarker = "golden-pr.png",

    // ONLY repos listed here will be queried
    // Format: "org/repo"
    ReposToInclude = {
        "TRO-TRM/Webgoat2",
        "TRO-TRM/webgoat1",
        "TRO-TRM/Webgoat3",
        "CDO-KP-ORG/kpmobilebff-parentpom",
        "HPBIO-KPMC/cac_bff_ms",
        "HPBIO-KPMC/cac_request_ms",
        "CDTS-TeleHealth/hca-biz-directorysearch",
        "CDTS-TeleHealth/hca-biz-directorystream",
        "CDTS-TeleHealth/hca-biz-directorycachebuilder"
    },

    // Auth (keep Anonymous in Data Source Settings)
    // NOTE: original hardcoded token was REDACTED here. Rotate the old one (it was exposed in screenshots)
    // and either paste the new value below, or — preferred — replace this with a Power BI parameter.
    Token = "<YOUR_TOKEN_HERE>",

    DefaultHeaders =
        if Token <> "<YOUR_TOKEN_HERE>" and Token <> ""
        then [ Authorization = "Bearer " & Token, Accept = "application/vnd.github+json" ]
        else [ Accept = "application/vnd.github+json" ],

    // ============================
    // 2) SAFE JSON FETCH
    // ============================
    GetJsonSafe = (relativePath as text, optional query as nullable record) as any =>
        let
            response =
                try
                    Web.Contents(
                        Host,
                        [
                            RelativePath = relativePath,
                            Query        = query,
                            Headers      = DefaultHeaders
                        ]
                    )
                otherwise
                    null,
            json = if response = null then null else Json.Document(response)
        in
            json,

    // ============================
    // 3) PAGINATION (page / per_page)
    // ============================
    GetAllPagesAsList = (relativePath as text, baseQuery as record) as list =>
        let
            GetPage = (page as number) as list =>
                let
                    q =
                        Record.AddField(
                            Record.AddField(baseQuery, "per_page", "100"),
                            "page",
                            Text.From(page)
                        ),
                    j      = GetJsonSafe(relativePath, q),
                    asList = if j is list then j else {}
                in
                    asList,
            pages =
                List.Generate(
                    () => [p = 1, items = GetPage(1)],
                    each List.Count([items]) > 0,
                    each [p = [p] + 1, items = GetPage([p] + 1)],
                    each [items]
                )
        in
            List.Combine(pages),

    // ============================
    // 4) HELPERS (golden marker + parse "#123")
    // ============================
    ContainsKeyword = (txt as nullable text) as logical =>
        if txt = null then false else Text.Contains(txt, GoldenMarker, Comparer.OrdinalIgnoreCase),

    Digits = {"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"},

    // Extract first PR number after the first '#' found in text (e.g., "... (#123) ...")
    ExtractFirstHashNumber = (txt as nullable text) as nullable number =>
        let
            t     = if txt = null then "" else txt,
            pos   = Text.PositionOf(t, "#", Occurrence.First),
            after = if pos < 0 then "" else Text.Range(t, pos + 1),
            chars = Text.ToList(after),
            takeDigits =
                List.Generate(
                    () => [i = 0, keep = true],
                    each [keep] and [i] < List.Count(chars),
                    each [
                        i    = [i] + 1,
                        keep = List.Contains(Digits, chars{[i]})
                    ],
                    each if List.Contains(Digits, chars{[i]}) then chars{[i]} else null
                ),
            digitList = List.RemoveNulls(takeDigits),
            digitText = Text.Combine(digitList, ""),
            result    = try Number.FromText(digitText) otherwise null
        in
            if digitText = "" then null else result,

    // ============================
    // 5) FETCH atlasId FROM pipeline.json
    // ============================
    // Extract a JSON string value by key from raw text (handles duplicate-key JSON that Json.Document rejects)
    ExtractJsonValue = (txt as text, key as text) as nullable text =>
        let
            // Search for "key": "value" or "key" : "value"
            searchKey   = """" & key & """",
            pos         = Text.PositionOf(txt, searchKey, Occurrence.First),
            afterKey    = if pos >= 0 then Text.Range(txt, pos + Text.Length(searchKey)) else null,
            // Skip whitespace and colon
            trimmed     = if afterKey <> null then Text.TrimStart(afterKey) else null,
            afterColon  = if trimmed <> null and Text.StartsWith(trimmed, ":") then Text.TrimStart(Text.Range(trimmed, 1)) else null,
            // Extract quoted value
            startsQuote = if afterColon <> null and Text.StartsWith(afterColon, """") then Text.Range(afterColon, 1) else null,
            endQuote    = if startsQuote <> null then Text.PositionOf(startsQuote, """", Occurrence.First) else -1,
            value       = if endQuote > 0 then Text.Range(startsQuote, 0, endQuote) else null
        in
            value,

    GetAtlasId = (fullName as text) as nullable text =>
        let
            parts   = Text.Split(fullName, "/"),
            owner   = parts{0},
            repo    = parts{1},
            rel     = ApiRoot & "/repos/" & owner & "/" & repo & "/contents/pipeline.json",
            json    = GetJsonSafe(rel, null),
            content = if json <> null then try json[content] otherwise null else null,
            // Keep ONLY valid base64 characters
            cleanContent =
                if content <> null
                then Text.Select(content, {"A".."Z", "a".."z", "0".."9", "+", "/", "="})
                else null,
            decoded =
                if cleanContent <> null
                then try Text.FromBinary(Binary.FromText(cleanContent, BinaryEncoding.Base64)) otherwise null
                else null,
            // Extract atlasId via text search (avoids Json.Document failing on duplicate keys)
            atlasId =
                if decoded <> null then
                    let
                        v1 = ExtractJsonValue(decoded, "atlasId"),
                        v2 = if v1 = null then ExtractJsonValue(decoded, "atlas-id") else v1
                    in
                        v2
                else null
        in
            atlasId,

    // ============================
    // 6) REPO LIST -> PRs
    // ============================
    ReposTable =
        Table.FromList(
            ReposToInclude,
            Splitter.SplitByNothing(),
            {"full_name"},
            null,
            ExtraValues.Error
        ),

    // Add AtlasId column (one API call per repo, not per PR)
    ReposWithAtlasId =
        Table.AddColumn(ReposTable, "AtlasId", each GetAtlasId([full_name]), type text),

    PRsForRepo = (fullName as text) as list =>
        let
            parts = Text.Split(fullName, "/"),
            owner = parts{0},
            repo  = parts{1},
            rel   = ApiRoot & "/repos/" & owner & "/" & repo & "/pulls",
            prs   = GetAllPagesAsList(rel, [state = "all"])
        in
            prs,

    ReposWithPRs =
        Table.AddColumn(
            ReposWithAtlasId,
            "prs",
            each PRsForRepo([full_name]),
            type list
        ),

    PRsExpanded1 = Table.ExpandListColumn(ReposWithPRs, "prs"),

    PRsExpanded2 =
        Table.ExpandRecordColumn(
            PRsExpanded1,
            "prs",
            {"number", "state", "title", "body", "user", "created_at", "closed_at", "merged_at", "updated_at", "html_url"},
            {"pr_number", "state", "title", "body", "user", "created_at", "closed_at", "merged_at", "updated_at", "html_url"}
        ),

    PRsExpanded3 =
        Table.ExpandRecordColumn(
            PRsExpanded2,
            "user",
            {"login"},
            {"author"}
        ),

    // Flag golden PR marker (golden-pr.png) in title/body -> sets HasAutoPR
    WithAutoPR =
        Table.AddColumn(
            PRsExpanded3,
            "HasAutoPR",
            each ContainsKeyword([title]) or ContainsKeyword([body]),
            type logical
        ),

    // ============================
    // 7) DETECT REVERT PRs + LINK THEM TO ORIGINAL PRs
    // ============================
    // Heuristic: revert PRs usually start with "Revert" and reference original PR number like "(#123)"
    // GitHub documents that reverting a PR creates a new PR that contains the revert.
    WithRevertFlags =
        Table.AddColumn(
            WithAutoPR,
            "IsRevertPR",
            each Text.StartsWith(Text.Trim([title] & ""), "Revert", Comparer.OrdinalIgnoreCase),
            type logical
        ),

    WithRevertsPRNumber =
        Table.AddColumn(
            WithRevertFlags,
            "RevertsPRNumber",
            each if [IsRevertPR] then ExtractFirstHashNumber([title] & " " & [body]) else null,
            Int64.Type
        ),

    // Table of (repo, revert_pr_number -> original_pr_number)
    RevertMap =
        Table.SelectRows(WithRevertsPRNumber, each [IsRevertPR] = true and [RevertsPRNumber] <> null),

    RevertMapSlim =
        Table.SelectColumns(RevertMap, {"full_name", "pr_number", "RevertsPRNumber", "html_url"}),

    RevertMapRenamed =
        Table.RenameColumns(
            RevertMapSlim,
            {{"pr_number", "RevertPRNumber"}, {"html_url", "RevertPRUrl"}}
        ),

    // Join originals to find which PRs were reverted (can be multiple revert PRs in rare cases)
    OriginalsWithRevertJoin =
        Table.NestedJoin(
            WithRevertsPRNumber,
            {"full_name", "pr_number"},
            RevertMapRenamed,
            {"full_name", "RevertsPRNumber"},
            "RevertInfo",
            JoinKind.LeftOuter
        ),

    WithRevertedBy =
        Table.AddColumn(
            OriginalsWithRevertJoin,
            "RevertedByPRs",
            each
                let t = [RevertInfo]
                in
                    if t = null or Table.RowCount(t) = 0
                    then null
                    else Text.Combine(List.Transform(Table.Column(t, "RevertPRNumber"), each Text.From(_)), ","),
            type text
        ),

    WithRevertedByUrl =
        Table.AddColumn(
            WithRevertedBy,
            "RevertedByUrls",
            each
                let t = [RevertInfo]
                in
                    if t = null or Table.RowCount(t) = 0
                    then null
                    else Text.Combine(List.Transform(Table.Column(t, "RevertPRUrl"), each _), ","),
            type text
        ),

    WithRevertedBySearchTerms =
        Table.AddColumn(
            WithRevertedByUrl,
            "RevertedBySearchTerms",
            each
                let t = [RevertInfo]
                in
                    if t = null or Table.RowCount(t) = 0
                    then null
                    else Text.Combine(List.Transform(Table.Column(t, "RevertPRNumber"), each "%23" & Text.From(_)), "+OR+"),
            type text
        ),

    WithRevertedByGlobalSearchTerms =
        Table.AddColumn(
            WithRevertedBySearchTerms,
            "RevertedByGlobalSearchTerms",
            each
                let
                    t             = [RevertInfo],
                    repoQualifier = "repo%3A" & Text.Replace([full_name], "/", "%2F")
                in
                    if t = null or Table.RowCount(t) = 0
                    then null
                    else Text.Combine(List.Transform(Table.Column(t, "RevertPRNumber"), each repoQualifier & "+%23" & Text.From(_)), "+OR+"),
            type text
        ),

    // For revert PR rows, bring in whether the target original PR had AutoPR so we can include revert PRs even if they don't contain AutoPR
    RevertTargetJoin =
        Table.NestedJoin(
            WithRevertedByGlobalSearchTerms,
            {"full_name", "RevertsPRNumber"},
            Table.SelectColumns(WithRevertedByGlobalSearchTerms, {"full_name", "pr_number", "HasAutoPR"}),
            {"full_name", "pr_number"},
            "TargetOriginal",
            JoinKind.LeftOuter
        ),

    WithTargetHasAutoPR =
        Table.AddColumn(
            RevertTargetJoin,
            "TargetOriginalHasAutoPR",
            each
                if [IsRevertPR] = true then
                    let t = [TargetOriginal]
                    in if t <> null and Table.RowCount(t) > 0 then t{0}[HasAutoPR] else false
                else
                    null,
            type logical
        ),

    // ============================
    // 8) CLASSIFY + FILTER OUTPUT
    // ============================
    WithPRType =
        Table.AddColumn(
            WithTargetHasAutoPR,
            "PR_Type",
            each
                if [IsRevertPR] then "Revert PR"
                else if [RevertedByPRs] <> null and Text.Length([RevertedByPRs]) > 0 then "Reverted (original)"
                else "Normal PR",
            type text
        ),

    // Keep:
    // - PRs that contain the golden marker in title/body (HasAutoPR)
    // - PLUS revert PRs that revert a golden original
    Filtered =
        Table.SelectRows(
            WithPRType,
            each
                ([HasAutoPR] = true)
                or ([IsRevertPR] = true and [TargetOriginalHasAutoPR] = true)
        ),

    // Clean up nested columns
    Cleaned =
        Table.RemoveColumns(Filtered, {"RevertInfo", "TargetOriginal"}),

    // Add base URL for repo pulls page (used by DAX URL measures for matrix drill-through)
    WithRepoPullsUrl =
        Table.AddColumn(
            Cleaned,
            "repo_pulls_base_url",
            each Host & "/" & [full_name] & "/pulls",
            type text
        ),

    WithGithubSearchUrl =
        Table.AddColumn(
            WithRepoPullsUrl,
            "github_search_base_url",
            each Host & "/search?q=",
            type text
        ),

    // Optional: types
    Typed =
        Table.TransformColumnTypes(
            WithGithubSearchUrl,
            {
                {"pr_number", Int64.Type},
                {"created_at", type datetimezone},
                {"closed_at", type datetimezone},
                {"merged_at", type datetimezone},
                {"updated_at", type datetimezone},
                {"RevertsPRNumber", Int64.Type}
            }
        )
in
    Typed
