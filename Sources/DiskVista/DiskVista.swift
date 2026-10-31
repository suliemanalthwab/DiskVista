import SwiftUI
import Charts
import LocalAuthentication
import AppKit
import Darwin

struct DiskEntry: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let bytes: Int64
    let count: Int
    var name: String { url.lastPathComponent }
}
struct ScanResult: Sendable {
    var groups: [DiskEntry] = []
    var files: [DiskEntry] = []
    var skipped = 0
    var total: Int64 = 0
    var excluded = 0
    var scannedFiles = 0
}
enum DiskScanner {
    static func scan(_ requestedRoot: URL, excluding excluded: Set<String> = [], comprehensive: Bool = false, progress: @Sendable (ScanResult) -> Void = { _ in }) throws -> ScanResult {
        let root = requestedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        var result = ScanResult()
        var groups: [String: (URL, Int64, Int)] = [:]
        var lastUpdate = Date.distantPast
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: comprehensive ? [] : [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, _ in result.skipped += 1; return true }) else { return result }
        for case let url as URL in walker {
            try Task.checkCancellation()
            if excluded.contains(url.standardizedFileURL.path) {
                walker.skipDescendants(); result.excluded += 1; continue
            }
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { continue }
                guard values.isRegularFile == true else { continue }
                let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                var groupURL = url
                for _ in 1..<max(1, walker.level) { groupURL.deleteLastPathComponent() }
                let first = groupURL.lastPathComponent
                let old = groups[first] ?? (groupURL, 0, 0)
                groups[first] = (groupURL, old.1 + bytes, old.2 + 1)
                result.total += bytes
                result.scannedFiles += 1
                result.files.append(DiskEntry(url: url, bytes: bytes, count: 1))
                if result.files.count > 1000 { result.files.sort { $0.bytes > $1.bytes }; result.files = Array(result.files.prefix(500)) }
                if Date().timeIntervalSince(lastUpdate) > 0.5 {
                    var snapshot = result
                    snapshot.groups = groups.values.map { DiskEntry(url: $0.0, bytes: $0.1, count: $0.2) }.sorted { $0.bytes > $1.bytes }
                    snapshot.files = Array(result.files.sorted { $0.bytes > $1.bytes }.prefix(500))
                    progress(snapshot); lastUpdate = Date()
                }
            } catch { result.skipped += 1 }
        }
        result.groups = groups.values.map { DiskEntry(url: $0.0, bytes: $0.1, count: $0.2) }.sorted { $0.bytes > $1.bytes }
        result.files.sort { $0.bytes > $1.bytes }
        result.files = Array(result.files.prefix(500))
        return result
    }
}
func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

@MainActor final class DiskModel: ObservableObject {
    @Published var root: URL?
    @Published var result = ScanResult()
    @Published var scanning = false
    @Published var status = "جارٍ قراءة معلومات القرص…"
    @Published var volumeName = "القرص الداخلي"
    @Published var capacityError = false
    @Published var quickScan = true
    @Published var comprehensive = false
    @Published var history: [URL] = []
    @Published var capacity: Int64 = 0
    @Published var available: Int64 = 0
    @Published var pending: DiskEntry?
    @Published var message: String?
    @Published var deleting = false
    private var worker: Task<ScanResult, Error>?
    private var generation = UUID()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        scan(FileManager.default.homeDirectoryForCurrentUser, quick: true)
    }
    func refresh() { if let root { scan(root, quick: quickScan, full: comprehensive, recordHistory: false) } }
    func loadCapacity(_ url: URL) {
        do {
            let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey])
            guard let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity else { throw CocoaError(.fileReadUnknown) }
            capacity = Int64(total); available = Int64(free)
            volumeName = values.volumeName ?? "القرص المحدد"; capacityError = false
        } catch { capacityError = true }
    }

    func chooseLocation(_ url: URL) {
        choose(startingAt: url)
    }
    func choose() { choose(startingAt: nil) }
    private func choose(startingAt url: URL?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "تحليل المجلد"
        panel.directoryURL = url
        panel.message = "اختر المجلد الذي تريد إضافة تفاصيله إلى الفحص. قد يطلب macOS إذن الوصول إليه."
        if panel.runModal() == .OK, let url = panel.url { scan(url) }
    }
    func cancel() { worker?.cancel(); generation = UUID(); scanning = false; status = "تم إلغاء الفحص" }
    func scan(_ url: URL, quick: Bool = false, full: Bool = false, recordHistory: Bool = true) {
        if recordHistory, let root, root != url { history.append(root) }
        comprehensive = full
        worker?.cancel()
        let token = UUID(); generation = token
        root = url; quickScan = quick; scanning = true; result = ScanResult()
        status = full ? "جارٍ الفحص الشامل — قد يستغرق عدة دقائق" : quick ? "جارٍ الفحص السريع" : "جارٍ فحص المجلد الذي اخترته…"
        loadCapacity(url)
        // Avoid entering privacy-protected locations during automatic scans.
        // Explicit selection in NSOpenPanel is the user's opt-in for a protected folder.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let protectedNames = ["Library", "Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies"]
        let privacyExclusions = Set(protectedNames.map { home.appendingPathComponent($0).standardizedFileURL.path })
            .subtracting([url.standardizedFileURL.path])
        let exclusions: Set<String> = full
            ? Set(["Volumes", "dev", "Network"].map { url.appendingPathComponent($0).standardizedFileURL.path })
            : privacyExclusions
        let recipient = self
        let task = Task.detached(priority: .userInitiated) {
            try DiskScanner.scan(url, excluding: exclusions, comprehensive: full) { snapshot in
                Task { @MainActor in
                    guard recipient.generation == token, recipient.scanning else { return }
                    recipient.result = snapshot
                    recipient.status = "جارٍ الفحص • \(snapshot.scannedFiles) ملف • \(size(snapshot.total))"
                }
            }
        }
        worker = task
        Task {
            do {
                let value = try await task.value
                guard generation == token else { return }
                result = value; scanning = false
                status = "اكتمل الفحص • \(value.scannedFiles) ملف • \(value.skipped) تعذّر قراءتها • \(value.excluded) مجلدات مستثناة"
            } catch {
                guard generation == token else { return }
                scanning = false; status = "توقف الفحص: \(error.localizedDescription)"
            }
        }
    }
    func scanDisk() {
        history = []
        let data = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        scan(FileManager.default.fileExists(atPath: data.path) ? data : URL(fileURLWithPath: "/"), full: true, recordHistory: false)
    }
    func back() {
        guard let previous = history.popLast() else { return }
        scan(previous, full: comprehensive, recordHistory: false)
    }
    func openEntry(_ entry: DiskEntry) {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: entry.url.path, isDirectory: &directory), directory.boolValue {
            scan(entry.url, full: comprehensive)
        } else { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
    }
    func canTrash(_ url: URL) -> Bool {
        func normalized(_ url: URL) -> String {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let data = "/System/Volumes/Data"
            if path == data { return "/" }
            return path.hasPrefix(data + "/") ? String(path.dropFirst(data.count)) : path
        }
        let path = normalized(url)
        let home = normalized(FileManager.default.homeDirectoryForCurrentUser)
        let protected = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/Applications", "/Users", home + "/Library", home + "/.Trash"]
        guard path != "/", path != home,
              !protected.contains(where: { path == $0 || (path.hasPrefix($0 + "/") && $0 != "/Users") }) else { return false }
        // Other users' homes and their data are never cleanup targets.
        if path.hasPrefix("/Users/"), !path.hasPrefix(home + "/") { return false }
        guard let root else { return false }
        let base = normalized(root)
        return path.hasPrefix(base == "/" ? "/" : base + "/")
    }
    func trash(_ entry: DiskEntry) {
        guard canTrash(entry.url), !deleting else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                let context = LAContext()
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "تأكيد نقل \(entry.name) إلى سلة المهملات")
                guard canTrash(entry.url) else { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
                message = "نُقل العنصر إلى سلة المهملات. يمكن استعادته من هناك. لن تتحرر المساحة حتى إفراغ السلة."
                refresh()
            } catch { message = "لم يُحذف العنصر: \(error.localizedDescription)" }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = DiskModel()
    @State private var files = false
    @State private var search = ""
    @State private var selection: String?
    @State private var selectedSector: Int64?
    @State private var showAccess = false
    @State private var showAbout = false
    @State private var showDevice = false
    @State private var showOther = false
    @State private var showUpdates = false
    private let palette: [Color] = [.blue, .cyan, .indigo, .purple, .pink, .orange, .teal, .gray]

    var entries: [DiskEntry] {
        (files ? model.result.files : model.result.groups).filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
        }
    }
    var selectedEntry: DiskEntry? { entries.first { $0.id == selection } }
    var chartEntries: [DiskEntry] {
        let groups = model.result.groups
        if groups.count <= 8 { return groups }
        return Array(groups.prefix(7)) + [DiskEntry(url: URL(fileURLWithPath: "/أخرى"), bytes: groups.dropFirst(7).reduce(0) { $0 + $1.bytes }, count: 0)]
    }
    var sector: DiskEntry? {
        guard let selectedSector else { return nil }
        var cumulative: Int64 = 0
        for entry in chartEntries {
            cumulative += entry.bytes
            if selectedSector < cumulative { return entry }
        }
        return nil
    }
    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 290)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        heading
                        diskSummary
                        overview
                    }.padding(24)
                }.frame(height: 465)
                Divider()
                fileBrowser
                footer
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(model.root?.lastPathComponent ?? "مساحة التخزين")
            .toolbar {
                ToolbarItemGroup {
                    Button("رجوع", systemImage: "chevron.backward", action: model.back).disabled(model.history.isEmpty || model.deleting)
                    Button("فحص شامل", systemImage: "internaldrive.badge.checkmark") { showAccess = true }.disabled(model.deleting)
                    if model.scanning {
                        ProgressView().controlSize(.small).accessibilityLabel("جارٍ الفحص")
                        Button("إيقاف الفحص", systemImage: "stop.circle", action: model.cancel)
                    } else {
                        Button("إعادة الفحص", systemImage: "arrow.clockwise") {
                            model.refresh()
                        }.disabled(model.root == nil || model.deleting)
                    }
                    Button("اختر مجلدًا", systemImage: "folder.badge.plus", action: model.choose)
                        .disabled(model.deleting)
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "ابحث عن ملف أو مجلد")
        }
        .frame(minWidth: 980, minHeight: 800)
        .environment(\.layoutDirection, .rightToLeft)
        .task { model.start() }
        .sheet(isPresented: $showAccess) { accessSheet }
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(isPresented: $showDevice) { deviceSheet }
        .sheet(isPresented: $showOther) { otherFoldersSheet }
        .sheet(isPresented: $showUpdates) { UpdateSettingsView() }
        .onChange(of: selectedSector) { _, value in
            guard value != nil, let entry = sector else { return }
            if model.result.groups.contains(where: { $0.id == entry.id }) {
                model.openEntry(entry)
            } else { showOther = true }
            selectedSector = nil
        }
        .onChange(of: model.root) { _, _ in selection = nil; selectedSector = nil }
        .onChange(of: files) { _, _ in selection = nil }
        .alert("نقل إلى سلة المهملات؟", isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } })) {
            if let entry = model.pending {
                Button("نقل إلى السلة", role: .destructive) { model.trash(entry); model.pending = nil }
            }
            Button("إلغاء", role: .cancel) { model.pending = nil }
        } message: {
            Text("\(model.pending?.url.path ?? "")\n\nسيُنقل العنصر وكل محتوياته إلى السلة بعد مصادقة النظام. يمكن استعادته من السلة.")
        }
        .alert("DiskVista", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("حسنًا") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var sidebar: some View {
        List {
            Section("المكتبة") {
                Button { model.scan(FileManager.default.homeDirectoryForCurrentUser, quick: true) } label: { Label("نظرة عامة", systemImage: "chart.pie.fill") }.buttonStyle(.plain).disabled(model.deleting)
                    .foregroundStyle(Color.accentColor)
                    .listRowBackground(Color.accentColor.opacity(0.1))
            }
            Section("الجهاز") {
                Button { showAccess = true } label: { Label("فحص القرص بالكامل", systemImage: "internaldrive") }.buttonStyle(.plain).disabled(model.deleting)
                Button { showDevice = true } label: { Label("معلومات الجهاز والأقراص", systemImage: "desktopcomputer") }.buttonStyle(.plain)
                Button { showUpdates = true } label: { Label("تحديث التطبيق", systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(.plain)
                Button { showAbout = true } label: { Label("حول DiskVista", systemImage: "info.circle") }.buttonStyle(.plain)
            }
            Section("الوصول السريع") {
                Button { model.scan(FileManager.default.homeDirectoryForCurrentUser, quick: true) } label: { Label("فحص سريع", systemImage: "bolt.fill") }.buttonStyle(.plain).disabled(model.deleting)
                location("التنزيلات", icon: "arrow.down.circle", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
                location("المستندات", icon: "doc", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"))
                location("سطح المكتب", icon: "menubar.dock.rectangle", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
                Button(action: model.choose) { Label("مجلد آخر…", systemImage: "folder.badge.plus") }
                    .buttonStyle(.plain).disabled(model.deleting)
            }
            if let root = model.root {
                Section("المجلد الحالي") {
                    Label(root.lastPathComponent, systemImage: "folder.fill")
                        .lineLimit(1).help(root.path)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Label("ملفاتك تبقى على جهازك", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .navigationTitle("DiskVista")
    }

    private func location(_ title: String, icon: String, url: URL) -> some View {
        Button { model.chooseLocation(url) } label: { Label(title, systemImage: icon) }
            .buttonStyle(.plain).disabled(model.deleting)
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 27)).foregroundStyle(.secondary)
                .frame(width: 54, height: 54)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text("مساحة التخزين").font(.system(size: 25, weight: .bold))
                Text(model.root?.path ?? "اختر مجلدًا لتعرف ما يشغل مساحة جهازك")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle).textSelection(.enabled)
            }
            Spacer()
            if model.root == nil {
                Button("اختر مجلدًا", action: model.choose).buttonStyle(.borderedProminent)
            }
        }
    }

    private var diskSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.volumeName, systemImage: "internaldrive").font(.headline)
                Spacer()
                Text("القرص بالكامل").font(.caption).foregroundStyle(.secondary)
            }
            if model.capacityError {
                Text("تعذّرت قراءة سعة القرص. أعد الفحص للمحاولة مجددًا.").foregroundStyle(.secondary)
            } else {
                HStack {
                    capacityMetric("السعة الكلية", bytes: model.capacity, color: .primary)
                    Spacer()
                    capacityMetric("المستخدم", bytes: max(0, model.capacity - model.available), color: .blue)
                    Spacer()
                    capacityMetric("المتاح", bytes: model.available, color: .green)
                }
                ProgressView(value: Double(max(0, model.capacity - model.available)), total: Double(max(1, model.capacity))).tint(.blue)
            }
            if model.quickScan {
                Text("الفحص السريع يتجاوز المجلدات المحمية والمخفية. لإضافة تفاصيل مجلد محمي، اختره بنفسك من الشريط الجانبي.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
    private func capacityMetric(_ title: String, bytes: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(size(bytes)).font(.system(size: 21, weight: .semibold, design: .rounded)).foregroundStyle(color).monospacedDigit()
        }
    }

    private var overview: some View {
        HStack(spacing: 28) {
            ZStack {
                if model.result.total > 0 {
                    Chart(chartEntries) { entry in
                        SectorMark(angle: .value("المساحة", entry.bytes), innerRadius: .ratio(0.80), angularInset: 2)
                            .cornerRadius(3)
                            .foregroundStyle(by: .value("العنصر", entry.id))
                            .opacity(sector == nil || sector?.id == entry.id ? 1 : 0.3)
                    }
                    .chartForegroundStyleScale(domain: chartEntries.map(\.id), range: palette)
                    .chartLegend(.hidden).chartAngleSelection(value: $selectedSector).disabled(model.deleting)
                } else {
                    Circle().stroke(Color.primary.opacity(0.07), lineWidth: 15).padding(9)
                }
                VStack(spacing: 5) {
                    Text(size(sector?.bytes ?? model.result.total)).font(.system(size: 23, weight: .semibold, design: .rounded)).contentTransition(.numericText())
                    Text(sector?.name ?? "تم تحليلها").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(width: 130)
            }.frame(width: 175, height: 175)
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("اضغط على الرسم لفتح المجلد").font(.headline)
                    Spacer()
                    Text("\(model.result.groups.count) عناصر").font(.caption).foregroundStyle(.secondary)
                }
                if chartEntries.isEmpty {
                    Text(model.scanning ? "تظهر النتائج تدريجيًا أثناء الفحص…" : "لم نعثر على ملفات متاحة في هذا المجلد.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                        ForEach(Array(chartEntries.enumerated()), id: \.element.id) { index, entry in
                            Button { if model.result.groups.contains(where: { $0.id == entry.id }) { model.openEntry(entry) } else { showOther = true } } label: {
                            HStack(spacing: 6) {
                                Circle().fill(palette[index]).frame(width: 7, height: 7)
                                Text(entry.name).lineLimit(1)
                                Spacer(minLength: 3)
                                Text(size(entry.bytes)).foregroundStyle(.secondary).monospacedDigit()
                            }.font(.caption)
                            }.buttonStyle(.plain).help("فتح \(entry.name)").disabled(model.deleting)
                        }
                    }
                }
                Divider()
                HStack {
                    Text("هذا التحليل يغطي الملفات المتاحة فقط، وليس كل المساحة المستخدمة.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }.font(.callout)
                ProgressView(value: Double(max(0, model.capacity - model.available)), total: Double(max(1, model.capacity)))
                    .tint(.blue).accessibilityLabel("المساحة المستخدمة على القرص")
            }.frame(maxWidth: .infinity)
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.07)))
    }

    private var fileBrowser: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("العرض", selection: $files) {
                    Text("المجلدات والعناصر").tag(false)
                    Text("أكبر الملفات").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 285)
                Spacer()
                if let entry = selectedEntry {
                    Button("فتح", systemImage: "arrow.turn.down.left") { model.openEntry(entry) }.disabled(model.deleting)
                    Button("إظهار في Finder", systemImage: "folder") { reveal(entry) }
                    Button("نقل إلى السلة", systemImage: "trash", role: .destructive) { model.pending = entry }
                        .disabled(!model.canTrash(entry.url) || model.scanning || model.deleting)
                }
            }.controlSize(.small).padding(.horizontal, 24).padding(.vertical, 12)
            Table(entries, selection: $selection) {
                TableColumn("الاسم") { entry in
                    HStack(spacing: 9) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path)).resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).lineLimit(1)
                            Text(entry.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }.padding(.vertical, 5)
                    .contextMenu { contextActions(entry) }
                }.width(min: 220, ideal: 380)
                TableColumn("الحجم") { entry in
                    Text(size(entry.bytes)).monospacedDigit().foregroundStyle(.secondary)
                }.width(100)
                TableColumn("النسبة") { entry in
                    HStack(spacing: 7) {
                        ProgressView(value: Double(entry.bytes), total: Double(max(1, model.result.total)))
                            .frame(width: 48).tint(.blue)
                        Text((Double(entry.bytes) / Double(max(1, model.result.total))).formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }.width(100)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label(model.scanning ? "جارٍ فحص الملفات" : search.isEmpty ? "ابدأ بمجلد" : "لا توجد نتائج", systemImage: model.scanning ? "externaldrive.badge.timemachine" : search.isEmpty ? "folder" : "magnifyingglass")
                    } description: {
                        Text(model.scanning ? "النتائج تظهر تدريجيًا، ويمكنك متابعة مساحة القرص في الأعلى الآن." : search.isEmpty ? "لإظهار مجلد محمي مثل التنزيلات، اختره مرة واحدة من زر اختر مجلدًا." : "جرّب البحث باسم آخر.")
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private var accessSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("فحص شامل بخطوات بسيطة", systemImage: "externaldrive.badge.checkmark").font(.title2.bold())
            Text("يحلّل التطبيق قرص البيانات، بما فيه الملفات المخفية ومحتويات التطبيقات. يظل التحليل محليًا؛ منح الوصول الكامل يسمح بقراءة ملفات حساسة أيضًا.").foregroundStyle(.secondary)
            Text("١. افتح إعدادات الوصول الكامل للقرص.\n٢. اضغط + وأضف DiskVista ثم فعّل المفتاح.\n٣. أعد فتح التطبيق إذا طلب النظام ذلك، ثم اختر ابدأ الفحص.")
                .lineSpacing(7)
            HStack {
                Button("فتح إعدادات الوصول") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"), !NSWorkspace.shared.open(url) {
                        model.message = "افتح إعدادات النظام ← الخصوصية والأمان ← الوصول الكامل للقرص."
                    }
                }
                Button("إظهار التطبيق لإضافته") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
            }
            Text("لا يستطيع التطبيق تفعيل الإذن بنفسه. يمكنك بدء الفحص دون منحه، لكن النتائج ستكون جزئية. تبقى بعض ملفات النظام محمية، ولا تشمل الأرقام لقطات APFS أو الأقراص الأخرى.").font(.caption).foregroundStyle(.secondary)
            Link("شرح الصلاحية من Apple", destination: URL(string: "https://support.apple.com/en-au/guide/mac-help/mchl211c911f/mac")!)
            Divider()
            HStack {
                Button("إلغاء") { showAccess = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("ابدأ الفحص") { showAccess = false; model.scanDisk() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 540).environment(\.layoutDirection, .rightToLeft)
    }

    private var deviceSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("جهازك وأقراص التخزين", systemImage: "desktopcomputer").font(.title2.bold())
            LabeledContent("الجهاز", value: Host.current().localizedName ?? "Mac")
            LabeledContent("الطراز", value: systemValue("hw.model"))
            LabeledContent("المعالج", value: systemValue("machdep.cpu.brand_string"))
            LabeledContent("الذاكرة", value: size(Int64(ProcessInfo.processInfo.physicalMemory)))
            LabeledContent("النظام", value: ProcessInfo.processInfo.operatingSystemVersionString)
            LabeledContent("أنوية المعالج", value: String(ProcessInfo.processInfo.processorCount))
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey], options: [.skipHiddenVolumes]) ?? [], id: \.path) { url in
                        let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(values?.volumeName ?? url.lastPathComponent, systemImage: "externaldrive")
                                Text("السعة \(size(Int64(values?.volumeTotalCapacity ?? 0))) • المتاح \(size(Int64(values?.volumeAvailableCapacity ?? 0)))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("فحص") { showDevice = false; model.chooseLocation(url) }.disabled(model.deleting)
                        }
                    }
                }
            }.frame(maxHeight: 180)
            Text("قد تتشارك وحدات APFS المساحة نفسها؛ لا تجمع سعاتها. زر الفحص يتيح تأكيد القرص في نافذة الاختيار.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("تم") { showDevice = false }.keyboardShortcut(.cancelAction) }
        }.padding(28).frame(width: 570).environment(\.layoutDirection, .rightToLeft)
    }
    private var otherFoldersSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("المجلدات الأخرى").font(.title2.bold())
            List(model.result.groups.dropFirst(7)) { entry in
                Button { showOther = false; model.openEntry(entry) } label: {
                    HStack { Text(entry.name); Spacer(); Text(size(entry.bytes)).foregroundStyle(.secondary) }
                }.buttonStyle(.plain).disabled(model.deleting)
            }.frame(height: 280)
            Button("إغلاق") { showOther = false }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 470).environment(\.layoutDirection, .rightToLeft)
    }

    private func reveal(_ entry: DiskEntry) { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
    @ViewBuilder private func contextActions(_ entry: DiskEntry) -> some View {
        Button("فتح التفاصيل") { model.openEntry(entry) }.disabled(model.deleting)
        Button("إظهار في Finder") { reveal(entry) }
        Divider()
        Button("نقل إلى السلة…", role: .destructive) { model.pending = entry }
            .disabled(!model.canTrash(entry.url) || model.scanning || model.deleting)
    }
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if model.deleting { ProgressView().controlSize(.mini) }
                Text(model.deleting ? "بانتظار مصادقة النظام…" : model.status).lineLimit(1)
                Spacer()
                Image(systemName: "info.circle")
                    .help("الأحجام للملفات المقروءة فقط، يشمل الفحص الشامل محتويات الحزم. لا تشمل الأرقام لقطات APFS. النقل للسلة يتطلب مصادقة النظام؛ لا تتحرر المساحة حتى إفراغ السلة.")
                Text("\(entries.count) عناصر")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
        }
    }
}
func systemValue(_ key: String) -> String {
    var length = 0
    guard sysctlbyname(key, nil, &length, nil, 0) == 0, length > 0 else { return "غير متاح" }
    var buffer = [CChar](repeating: 0, count: length)
    guard sysctlbyname(key, &buffer, &length, nil, 0) == 0 else { return "غير متاح" }
    return String(cString: buffer)
}
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 100, height: 100)
            Text("DiskVista").font(.largeTitle.bold())
            Text("الإصدار \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "نسخة تطوير")").font(.caption).foregroundStyle(.secondary)
            Text("مساحة جهازك، بوضوح.").foregroundStyle(.secondary)
            Divider()
            Text("فكرة سليمان الثواب").font(.headline)
            Text("برمجة Codex")
            Text("تطبيق مجاني مفتوح المصدر — ترخيص MIT").foregroundStyle(.secondary)
            Link("sulieman.my", destination: URL(string: "https://sulieman.my/")!)
            Button("تم") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(32).frame(width: 390).environment(\.layoutDirection, .rightToLeft)
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateManager.shared.start()
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}
@main struct DiskVistaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var about = false
    var body: some Scene {
        WindowGroup { ContentView().sheet(isPresented: $about) { AboutView() } }.defaultSize(width: 1120, height: 880)
            .windowToolbarStyle(.unified)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("حول DiskVista") { about = true }
                    UpdateMenuButton()
                }
            }
    }
}
