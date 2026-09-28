import AppKit
import HDMCore
import SwiftUI

/// Quality picker for video links (spec §8.2 in-app variant): a yt-dlp query fills the list
/// ("1080p · MP4 · ~450 MB", "Audio only · M4A", …) and the choice becomes a media download.
/// When the URL turns out not to be a video page, the user can fall back to a regular download.
struct VideoInfoView: View {
    @Environment(AppModel.self) private var model
    let pending: PendingDownload
    let close: () -> Void

    private enum QueryState {
        case loading
        case loaded(VideoInfo)
        case failed(String, allowsFileFallback: Bool)
    }

    @State private var state: QueryState = .loading
    @State private var ffmpegAvailable = false
    @State private var selection: MediaFormatOption.ID?
    @State private var category: DownloadCategory = .video
    @State private var directory: URL = AppSettings.defaultBaseFolder
    @State private var userChoseCategory = false
    @State private var userChoseFolder = false
    @State private var rememberFolder = false
    @State private var name = ""
    @State private var userEditedName = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch state {
            case .loading:
                VStack(alignment: .leading, spacing: 10) {
                    Text(pending.url.absoluteString).lineLimit(2).truncationMode(.middle)
                        .foregroundStyle(.secondary).textSelection(.enabled)
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Getting video information…")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                .padding(.vertical, 30)
            case .loaded(let info):
                loadedView(info)
            case .failed(let message, let allowsFallback):
                VStack(alignment: .leading, spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(pending.url.absoluteString).lineLimit(2).truncationMode(.middle)
                        .foregroundStyle(.secondary).textSelection(.enabled)
                    if allowsFallback {
                        Text("This address is not a video page HDM recognises. You can download it as a regular file instead.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                .padding(.vertical, 20)
            }
            HStack {
                if case .failed(_, true) = state {
                    Button("Download as Regular File") {
                        model.windows.showDownloadInfo(pending)
                        close()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                if case .loaded = state {
                    Button("Download Later") { submit(start: false) }.disabled(selection == nil || name.isEmpty)
                    Button("Start Download") { submit(start: true) }.keyboardShortcut(.defaultAction)
                        .disabled(selection == nil || name.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .background(FitWindowToContent(trigger: layoutToken))
        .task { await query() }
    }

    private var layoutToken: String {
        switch state {
        case .loading: return "loading"
        case .failed(let message, _): return "failed-\(message.isEmpty)"
        case .loaded(let info): return "loaded-\(info.options.count)-\(category)"
        }
    }

    // MARK: - Loaded

    private func loadedView(_ info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "film").resizable().scaledToFit().frame(width: 44, height: 44)
                    .foregroundStyle(.tint).padding(2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.title).font(.title3).fontWeight(.semibold).lineLimit(2)
                    HStack(spacing: 8) {
                        if info.isLive { Text("LIVE").font(.caption.bold()).foregroundStyle(.red) }
                        if let duration = info.duration, !info.isLive {
                            Text(Format.duration(duration)).foregroundStyle(.secondary)
                        }
                        if let uploader = info.uploader {
                            Text(uploader).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("URL:").gridColumnAlignment(.trailing)
                    Text(pending.url.absoluteString).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                GridRow {
                    Text("Category:")
                    Picker("", selection: $category) {
                        ForEach(DownloadCategory.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .onChange(of: category) { _, _ in userChoseCategory = true }
                }
                GridRow {
                    Text("Save As:")
                    TextField("", text: nameBinding)
                }
                GridRow {
                    Text("Folder:")
                    HStack {
                        Text(directory.path(percentEncoded: false)).lineLimit(1).truncationMode(.head)
                            .foregroundStyle(.secondary).frame(maxWidth: 330, alignment: .leading)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Toggle("Remember this folder for this category", isOn: $rememberFolder).disabled(!userChoseFolder)
                }
            }
            Text("Quality:").foregroundStyle(.secondary)
            qualityList(info.options)
        }
    }

    private func qualityList(_ options: [MediaFormatOption]) -> some View {
        VStack(spacing: 0) {
            ForEach(options) { option in
                qualityRow(option)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { pick(option) }
                if option.id != options.last?.id { Divider().padding(.leading, 8) }
            }
        }
        .frame(maxHeight: 240)
        .overlay {
            RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25))
        }
    }

    private func qualityRow(_ option: MediaFormatOption) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selection == option.id ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selection == option.id ? Color.accentColor : Color.secondary)
            Text(option.label).frame(width: 110, alignment: .leading)
            Text(option.ext).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Text(option.approxSize.map { "~" + Format.bytes($0) } ?? "—")
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let note = option.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(option.disabled(ffmpegAvailable: ffmpegAvailable) ? 0.4 : 1)
    }

    // MARK: - Behaviour

    private var nameBinding: Binding<String> {
        Binding(get: { name }, set: { name = $0; userEditedName = true })
    }

    private func pick(_ option: MediaFormatOption) {
        guard !option.disabled(ffmpegAvailable: ffmpegAvailable) else { return }
        selection = option.id
        if option.audioOnly, !userChoseCategory, category == .video { category = .music }
        if !option.audioOnly, !userChoseCategory, category == .music { category = .video }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url {
            directory = url
            userChoseFolder = true
        }
    }

    private func query() async {
        let tools = ComponentLocator.locate()
        ffmpegAvailable = tools.ffmpeg != nil
        guard tools.ytDLP != nil else {
            state = .failed(String(localized: "yt-dlp is not installed. Install it with: brew install yt-dlp"), allowsFileFallback: true)
            return
        }
        do {
            let info = try await YTDLPRunner.query(pageURL: pending.url, headers: pending.headers, tools: tools)
            let video = FormatMapper.videoInfo(from: info,
                                               preferQuickTimeCompatible: model.settings.settings.preferQuickTimeCompatible)
            guard !video.options.isEmpty else {
                state = .failed(String(localized: "No downloadable formats were found for this video."), allowsFileFallback: false)
                return
            }
            state = .loaded(video)
            if !userEditedName { name = FilenameResolver.sanitize(video.title) }
            let best = video.options.first { !$0.disabled(ffmpegAvailable: ffmpegAvailable) } ?? video.options[0]
            selection = best.id
            category = best.audioOnly ? .music : .video
            userChoseCategory = false
            directory = model.settings.settings.folder(for: category)
        } catch MediaQueryError.unsupportedURL {
            state = .failed(String(localized: "This site is not supported by yt-dlp."), allowsFileFallback: true)
        } catch MediaQueryError.timedOut {
            state = .failed(String(localized: "Getting the video information timed out. Try again."), allowsFileFallback: false)
        } catch MediaQueryError.ytDLPNotFound {
            state = .failed(String(localized: "yt-dlp is not installed. Install it with: brew install yt-dlp"), allowsFileFallback: true)
        } catch MediaQueryError.failed(let message) {
            state = .failed(message, allowsFileFallback: false)
        } catch {
            state = .failed(error.localizedDescription, allowsFileFallback: false)
        }
    }

    private func submit(start: Bool) {
        guard case .loaded(let info) = state,
              let option = info.options.first(where: { $0.id == selection && !$0.disabled(ffmpegAvailable: ffmpegAvailable) }) else { return }
        if rememberFolder, userChoseFolder { model.settings.settings.categoryFolders[category] = directory }
        let base = FilenameResolver.sanitize(name)
        let job = MediaJob(sourceURL: pending.url, formatSelector: option.selector, sortSpec: option.sortSpec,
                           title: info.title, audioOnly: option.audioOnly,
                           approxTotalBytes: option.approxSize, headers: pending.headers)
        let id = model.manager.add(NewDownload(url: pending.url, fileName: base, directory: directory, category: category,
                                               headers: pending.headers, pageURL: pending.pageURL, referrer: pending.referrer,
                                               totalBytes: option.approxSize, autoStart: start, media: job))
        if start && model.settings.settings.showProgressWindow { model.windows.showProgress(id) }
        close()
    }
}

private extension MediaFormatOption {
    /// Audio-only rows need ffmpeg (extraction); callers disable them when it is missing.
    func disabled(ffmpegAvailable: Bool) -> Bool { audioOnly && !ffmpegAvailable }
}
