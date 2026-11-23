import SwiftUI
import PhotosUI
import AVFoundation
import CoreLocation

// MARK: - Textos traduzidos (idioma do sistema; se não existir, inglês)

func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}

// MARK: - Entrada da app

@main
struct JuntarVideosApp: App {
    var body: some Scene {
        Window(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Join Videos",
               id: "main") {
            ContentView()
                .frame(minWidth: 540, minHeight: 560)
        }
    }
}

// MARK: - Modelo

struct Clip: Identifiable, Equatable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
    var date: Date? { asset.creationDate }
    var duration: TimeInterval { asset.duration }
    var location: CLLocation? { asset.location }
    static func == (l: Clip, r: Clip) -> Bool { l.id == r.id }
}

enum MetaSource: CaseIterable, Identifiable {
    case first, oldest
    var id: Self { self }
    var title: String {
        switch self {
        case .first: return L("meta_first")
        case .oldest: return L("meta_oldest")
        }
    }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

enum MergeError: LocalizedError {
    case msg(String)
    var errorDescription: String? {
        if case .msg(let m) = self { return m }
        return nil
    }
}

struct TrackInfo {
    var size: CGSize
    var transform: CGAffineTransform
    var fps: Float
    var frame: CMTime
    var codec: FourCharCode

    func matches(_ o: TrackInfo) -> Bool {
        size == o.size && transform == o.transform && abs(fps - o.fps) < 0.5 && codec == o.codec
    }

    var displaySize: CGSize {
        let r = CGRect(origin: .zero, size: size).applying(transform)
        let w = (abs(r.width) / 2).rounded(.down) * 2
        let h = (abs(r.height) / 2).rounded(.down) * 2
        return CGSize(width: max(w, 2), height: max(h, 2))
    }
}

// MARK: - Miniaturas

enum Thumbnail {
    static func load(_ asset: PHAsset) async -> NSImage? {
        await withCheckedContinuation { cont in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat
            o.isNetworkAccessAllowed = true
            o.isSynchronous = false
            var finished = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 160, height: 160),
                contentMode: .aspectFill,
                options: o
            ) { img, info in
                // o Fotografias pode chamar mais de uma vez; só respondemos uma
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if finished || (degraded && img != nil) { return }
                finished = true
                cont.resume(returning: img)
            }
        }
    }
}

// MARK: - Lógica

@MainActor
final class ViewModel: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var pickerItems: [PhotosPickerItem] = []
    @Published var metaSource: MetaSource = .first
    @Published var isWorking = false
    @Published var phase = ""
    @Published var progress = 0.0
    @Published var alert: AlertInfo?

    private func accessAlert() -> AlertInfo {
        AlertInfo(title: L("access_title"), text: L("access_text"))
    }

    // Acesso ao Fotografias

    func requestAccess() async -> Bool {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return s == .authorized || s == .limited
    }

    // Seleção feita no seletor da app

    func loadSelection() async {
        let ids = pickerItems.compactMap { $0.itemIdentifier }
        guard !ids.isEmpty else { return }
        guard await requestAccess() else {
            alert = accessAlert()
            pickerItems = []
            return
        }
        addAssets(ids: ids)
        pickerItems = []
    }

    // Seleção feita no Fotografias (aberta pelo Serviço: juntarvideos://from-photos)

    func loadFromPhotosSelection() async {
        guard await requestAccess() else {
            alert = accessAlert()
            return
        }
        let src = """
        tell application "Photos"
            set out to {}
            repeat with m in (get selection)
                set end of out to id of m
            end repeat
            return out
        end tell
        """
        guard let script = NSAppleScript(source: src) else { return }
        var err: NSDictionary?
        let desc = script.executeAndReturnError(&err)
        if err != nil {
            alert = AlertInfo(title: L("fail_title"), text: L("err_automation"))
            return
        }
        var ids: [String] = []
        if desc.numberOfItems > 0 {
            for i in 1...desc.numberOfItems {
                if let s = desc.atIndex(i)?.stringValue { ids.append(s) }
            }
        }
        let before = clips.count
        addAssets(ids: ids)
        if clips.count == before {
            alert = AlertInfo(title: L("need_title"), text: L("err_selection"))
        }
    }

    private func addAssets(ids: [String]) {
        guard !ids.isEmpty else { return }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var found: [Clip] = []
        result.enumerateObjects { a, _, _ in
            if a.mediaType == .video { found.append(Clip(asset: a)) }
        }
        found.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        var all = clips
        for c in found where !all.contains(c) { all.append(c) }
        clips = all
    }

    func remove(_ clip: Clip) {
        clips.removeAll { $0 == clip }
    }

    func metaIndex() -> Int {
        guard !clips.isEmpty else { return 0 }
        switch metaSource {
        case .first:
            return 0
        case .oldest:
            var best = 0
            for (i, c) in clips.enumerated() {
                if (c.date ?? .distantFuture) < (clips[best].date ?? .distantFuture) { best = i }
            }
            return best
        }
    }

    // Fluxo principal

    func joinClips() async {
        guard clips.count >= 2 else {
            alert = AlertInfo(title: L("need_title"), text: L("need_text"))
            return
        }
        guard await requestAccess() else {
            alert = accessAlert()
            return
        }
        isWorking = true
        progress = 0
        defer { isWorking = false; phase = "" }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JuntarVideos-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let reference = clips[metaIndex()]
            let total = clips.count

            var urls: [URL] = []
            for (i, c) in clips.enumerated() {
                phase = LF("phase_prepare", i + 1, total)
                let u = try await exportOriginal(c.asset, to: dir, index: i)
                urls.append(u)
                progress = 0.4 * Double(i + 1) / Double(total)
            }

            let out = dir.appendingPathComponent("juntado.mov")
            try await merge(urls: urls, to: out)

            phase = L("phase_adding")
            progress = 0.95
            try await importToPhotos(out, date: reference.date, location: reference.location)
            progress = 1.0

            alert = AlertInfo(title: L("done_title"), text: LF("done_text", total))
            clips = []
        } catch {
            alert = AlertInfo(title: L("fail_title"), text: error.localizedDescription)
        }
    }

    // Exportar o ficheiro do Fotografias

    private func exportOriginal(_ asset: PHAsset, to dir: URL, index: Int) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let res = resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first(where: { $0.type == .video }) else {
            throw MergeError.msg(L("err_resource"))
        }
        let ext = (res.originalFilename as NSString).pathExtension
        let url = dir.appendingPathComponent("clip_\(index).\(ext.isEmpty ? "mov" : ext)")
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: res, toFile: url, options: opts)
        return url
    }

    // Juntar

    private func merge(urls: [URL], to out: URL) async throws {
        let assets = urls.map { AVURLAsset(url: $0) }

        var infos: [TrackInfo] = []
        for a in assets {
            guard let v = try await a.loadTracks(withMediaType: .video).first else {
                throw MergeError.msg(L("err_novideo"))
            }
            let size = try await v.load(.naturalSize)
            let t = try await v.load(.preferredTransform)
            let fps = try await v.load(.nominalFrameRate)
            let frame = try await v.load(.minFrameDuration)
            let fds = try await v.load(.formatDescriptions)
            let codec: FourCharCode = fds.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            infos.append(TrackInfo(size: size, transform: t, fps: fps, frame: frame, codec: codec))
        }

        // Composição: todos os clips, um a seguir ao outro
        let comp = AVMutableComposition()
        guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MergeError.msg(L("err_composition"))
        }
        let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        var ranges: [CMTimeRange] = []
        for a in assets {
            let dur = try await a.load(.duration)
            let range = CMTimeRange(start: .zero, duration: dur)
            if let v = try await a.loadTracks(withMediaType: .video).first {
                try vt.insertTimeRange(range, of: v, at: cursor)
            }
            if let au = try await a.loadTracks(withMediaType: .audio).first {
                try at?.insertTimeRange(range, of: au, at: cursor)
            }
            ranges.append(CMTimeRange(start: cursor, duration: dur))
            cursor = CMTimeAdd(cursor, dur)
        }

        // 1) Mesmo formato em todos: copiar sem recodificar (sem perda, mantém HDR)
        let compatible = infos.dropFirst().allSatisfy { $0.matches(infos[0]) }
        if compatible, let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) {
            phase = L("phase_lossless")
            vt.preferredTransform = infos[0].transform
            do {
                try await export(s, to: out)
                return
            } catch {
                try? FileManager.default.removeItem(at: out)
            }
        }

        // 2) Formatos diferentes: converter para o formato do primeiro clip
        phase = L("phase_convert")
        vt.preferredTransform = .identity
        let render = infos[0].displaySize

        var instructions: [AVMutableVideoCompositionInstruction] = []
        for (i, r) in ranges.enumerated() {
            let info = infos[i]
            let rect = CGRect(origin: .zero, size: info.size).applying(info.transform)
            let dw = max(abs(rect.width), 1), dh = max(abs(rect.height), 1)
            let scale = min(render.width / dw, render.height / dh)
            let ox = (render.width - dw * scale) / 2
            let oy = (render.height - dh * scale) / 2
            let t = info.transform
                .concatenating(CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: ox, y: oy))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
            layer.setTransform(t, at: r.start)
            let inst = AVMutableVideoCompositionInstruction()
            inst.timeRange = r
            inst.layerInstructions = [layer]
            instructions.append(inst)
        }

        let vc = AVMutableVideoComposition()
        vc.renderSize = render
        let f = infos[0].frame
        vc.frameDuration = (f.isValid && f.seconds > 0) ? f : CMTime(value: 1, timescale: 30)
        vc.instructions = instructions

        guard let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHEVCHighestQuality)
                ?? AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw MergeError.msg(L("err_export_start"))
        }
        s.videoComposition = vc
        try await export(s, to: out)
    }

    private func export(_ session: AVAssetExportSession, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        session.outputURL = url
        session.outputFileType = .mov
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                self.progress = 0.4 + 0.5 * Double(session.progress)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        await session.export()
        poll.cancel()
        if session.status != .completed {
            throw session.error ?? MergeError.msg(L("err_export"))
        }
    }

    // Importar com a data e a localização escolhidas

    private func importToPhotos(_ url: URL, date: Date?, location: CLLocation?) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .video, fileURL: url, options: nil)
            if let d = date { req.creationDate = d }
            if let l = location { req.location = l }
        }
    }
}

// MARK: - Interface

struct ContentView: View {
    @StateObject private var vm = ViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Join Videos")
                        .font(.largeTitle.bold())
                    Text(L("app_subtitle"))
                        .foregroundColor(.secondary)
                }
            }

            if vm.clips.isEmpty {
                emptyState
            } else {
                clipList
                controls
            }
        }
        .padding(20)
        .alert(vm.alert?.title ?? "",
               isPresented: Binding(get: { vm.alert != nil },
                                    set: { if !$0 { vm.alert = nil } }),
               presenting: vm.alert) { _ in
            Button(L("ok")) {}
        } message: { a in
            Text(a.text)
        }
        .onChange(of: vm.pickerItems) { _ in
            Task { await vm.loadSelection() }
        }
        .onOpenURL { url in
            if url.host == "from-photos" {
                Task { await vm.loadFromPhotosSelection() }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 54))
                .foregroundColor(.secondary)
            Text(L("empty_title"))
                .font(.headline)
            picker
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var picker: some View {
        PhotosPicker(selection: $vm.pickerItems,
                     matching: .videos,
                     photoLibrary: .shared()) {
            Label(L("pick_button"), systemImage: "plus.circle.fill")
        }
        .disabled(vm.isWorking)
    }

    private var clipList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("reorder_hint"))
                .font(.caption)
                .foregroundColor(.secondary)
            List {
                ForEach(Array(vm.clips.enumerated()), id: \.element.id) { index, clip in
                    ClipRow(clip: clip,
                            isMeta: index == vm.metaIndex(),
                            onRemove: { vm.remove(clip) })
                }
                .onMove { from, to in
                    vm.clips.move(fromOffsets: from, toOffset: to)
                }
            }
            .frame(minHeight: 200)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("meta_label"))
                Picker("", selection: $vm.metaSource) {
                    ForEach(MetaSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
            }

            if vm.clips.count >= 2 && !vm.isWorking {
                Text(L("format_note"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if vm.isWorking {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: vm.progress)
                    Text(vm.phase)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                picker
                Spacer()
                Button(L("clear")) { vm.clips = [] }
                    .disabled(vm.isWorking)
                Button {
                    Task { await vm.joinClips() }
                } label: {
                    Text(LF("join_n", vm.clips.count))
                        .frame(minWidth: 120)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(vm.isWorking || vm.clips.count < 2)
            }
        }
    }
}

struct ClipRow: View {
    let clip: Clip
    let isMeta: Bool
    let onRemove: () -> Void
    @State private var thumb: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let t = thumb {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.25))
                }
            }
            .frame(width: 64, height: 48)
            .clipped()
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.date?.formatted(date: .abbreviated, time: .shortened) ?? L("no_date"))
                    .font(.body)
                HStack(spacing: 8) {
                    Text(Self.format(clip.duration))
                    if clip.location != nil {
                        Label(L("has_location"), systemImage: "location.fill")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            if isMeta {
                Text(L("badge_meta"))
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.18))
                    .cornerRadius(8)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
        .task {
            thumb = await Thumbnail.load(clip.asset)
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
