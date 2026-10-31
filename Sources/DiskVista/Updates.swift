import SwiftUI
import Sparkle

/// Sparkle owns preferences and update validation; no custom installer or password handling.
@MainActor final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var automaticDownloads = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var unavailableReason: String?
    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil else { return }
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil else {
            unavailableReason = "التحديث متاح في نسخة التطبيق المجمّعة. ابنِ التطبيق عبر bash scripts/build-app.sh أو حمّله من GitHub."
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.sendsSystemProfile = false
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticDownloads)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheck)
        controller.startUpdater()
    }
    func check() { if canCheck { controller?.checkForUpdates(nil) } }
    func setChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
    func setDownloads(_ enabled: Bool) { controller?.updater.automaticallyDownloadsUpdates = enabled }
}

struct UpdateMenuButton: View {
    @ObservedObject private var updates = UpdateManager.shared
    var body: some View {
        Button("التحقق من التحديثات…", action: updates.check).disabled(!updates.canCheck)
    }
}

struct UpdateSettingsView: View {
    @ObservedObject private var updates = UpdateManager.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("تحديثات DiskVista", systemImage: "arrow.triangle.2.circlepath").font(.title2.bold())
            Text("الإصدار الحالي: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "تطوير")")
                .foregroundStyle(.secondary)
            if let reason = updates.unavailableReason {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            } else {
                Toggle("البحث عن تحديثات تلقائيًا", isOn: Binding(get: { updates.automaticChecks }, set: updates.setChecks))
                Toggle("تنزيل التحديثات وتثبيتها تلقائيًا", isOn: Binding(get: { updates.automaticDownloads }, set: updates.setDownloads))
                    .disabled(!updates.automaticChecks)
                Text("يتحقق التطبيق من توقيع التحديث قبل تثبيته. قد يطلب macOS تأكيدًا حسب موقع التطبيق وصلاحياته.")
                    .font(.caption).foregroundStyle(.secondary)
                if let lastCheck = updates.lastCheck {
                    LabeledContent("آخر تحقق", value: lastCheck.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                }
                Text("التحقق يتصل بـ GitHub لتنزيل معلومات الإصدار؛ لا يرسل نتائج فحص القرص أو أسماء ملفاتك.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("تم") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("التحقق الآن", action: updates.check).buttonStyle(.borderedProminent).disabled(!updates.canCheck)
            }
        }.padding(28).frame(width: 470).environment(\.layoutDirection, .rightToLeft)
    }
}
