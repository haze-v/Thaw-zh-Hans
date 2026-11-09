//
//  UpstreamReleaseTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation
import Testing
@testable import Thaw

@Suite("Upstream releases respect channel and semantic version")
struct UpstreamReleaseTests {
    @Test("Beta excludes alpha, drafts and legacy releases")
    func betaSelection() {
        let releases = ["2.99.0", "3.0.0-beta.9", "v3.0.0-beta.10", "4.0.0-alpha.1"].map {
            UpstreamRelease(tagName: $0, draft: false)
        } + [UpstreamRelease(tagName: "5.0.0", draft: true)]
        #expect(UpstreamRelease.latest(in: releases, channel: .beta)?.version == "3.0.0-beta.10")
        #expect(UpstreamRelease.latest(in: releases, channel: .alpha)?.version == "4.0.0-alpha.1")
    }

    @Test("Stable release supersedes prereleases and no match stays unknown")
    func stableSelection() {
        let releases = ["3.0.0-beta.10", "3.0.0"].map { UpstreamRelease(tagName: $0, draft: false) }
        #expect(UpstreamRelease.latest(in: releases, channel: .beta)?.version == "3.0.0")
        #expect(UpstreamRelease.latest(in: [], channel: .beta) == nil)
        #expect(UpstreamRelease.latest(in: [UpstreamRelease(tagName: "invalid", draft: false)], channel: .beta) == nil)
    }

    @Test("GitHub response decodes tags without relying on release names")
    func responseDecoding() throws {
        let data = Data(#"[{"tag_name":"v3.0.0-beta.7","draft":false,"name":"Release"}]"#.utf8)
        let releases = try JSONDecoder().decode([UpstreamRelease].self, from: data)
        #expect(UpstreamRelease.latest(in: releases, channel: .beta)?.version == "3.0.0-beta.7")
    }
}
