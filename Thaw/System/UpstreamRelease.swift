//
//  UpstreamRelease.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation

/// 官方发布信息，仅用于提醒汉化分支同步上游。
nonisolated struct UpstreamRelease: Decodable {
    let tagName: String
    let draft: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
    }

    var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    /// 按频道筛选 Thaw 3 及后续版本，再按语义版本选出最新发布。
    static func latest(in releases: [Self], channel: UpdateChannel) -> Self? {
        releases.filter { release in
            guard !release.draft, let major = Int(release.version.split(separator: ".").first ?? ""), major >= 3
            else { return false }
            guard let prerelease = ReleaseVersionOrder.prereleaseTag(of: release.version) else { return true }
            switch channel {
            case .stable: return false
            case .beta: return prerelease.hasPrefix("beta.") || prerelease.hasPrefix("rc.")
            case .alpha: return prerelease.hasPrefix("alpha.") || prerelease.hasPrefix("beta.") || prerelease.hasPrefix("rc.")
            }
        }.max { ReleaseVersionOrder.precedes($0.version, $1.version) }
    }
}
