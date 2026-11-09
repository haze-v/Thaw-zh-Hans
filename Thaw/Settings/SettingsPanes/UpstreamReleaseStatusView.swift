//
//  UpstreamReleaseStatusView.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

/// 在关于页检查上游版本，提醒用户保留汉化改动并合并更新。
struct UpstreamReleaseStatusView: View {
    let channel: UpdateChannel
    @State private var latestVersion: String?
    @State private var isChecking = false
    @State private var checkFailed = false
    @State private var refreshID = UUID()

    private var hasNewVersion: Bool {
        latestVersion.map { ReleaseVersionOrder.precedes(Constants.versionString, $0) } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Upstream version").font(.headline)
            Text("Current version: \(Constants.versionString)")
            if let latestVersion {
                Text("Latest upstream version: \(latestVersion)")
            }
            if isChecking {
                ProgressView("Checking upstream releases…").controlSize(.small)
            } else if checkFailed {
                Text("Could not check upstream releases. Try again later.")
                    .foregroundStyle(.secondary)
            } else if hasNewVersion {
                Label("New upstream release: fetch and merge it into your Chinese branch.", systemImage: "arrow.triangle.merge")
                    .foregroundStyle(.orange)
            } else if latestVersion != nil {
                Text("No newer upstream release in this channel.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Refresh upstream version") { refreshID = UUID() }
                    .disabled(isChecking)
                Link("View upstream releases", destination: Constants.repositoryURL.appendingPathComponent("releases"))
            }
            Text("Checks official GitHub releases when this page opens. Merge upstream changes before rebuilding the Chinese version.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
        .task(id: "\(channel.rawValue)-\(refreshID)") {
            await checkUpstream()
        }
    }

    /// 页面关闭或频道改变时取消请求，避免显示过期频道的检查结果。
    private func checkUpstream() async {
        isChecking = true
        checkFailed = false
        latestVersion = nil
        do {
            let url = URL(string: "https://api.github.com/repos/thaw-app/Thaw/releases?per_page=100")!
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                checkFailed = true
                isChecking = false
                return
            }
            let releases = try JSONDecoder().decode([UpstreamRelease].self, from: data)
            latestVersion = UpstreamRelease.latest(in: releases, channel: channel)?.version
            checkFailed = latestVersion == nil
        } catch {
            guard !Task.isCancelled else { return }
            checkFailed = true
        }
        isChecking = false
    }
}
