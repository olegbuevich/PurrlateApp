import SwiftUI
import AppKit
import NaturalLanguage
@preconcurrency import Translation // Translation types are not Sendable yet

// MARK: - App

@main
struct PurrlateApp: App {
    @StateObject private var controller = Controller()

    var body: some Scene {
        MenuBarExtra("Purrlate", systemImage: controller.isEnabled ? "character.bubble.fill" : "character.bubble") {
            Toggle("On/Off", isOn: $controller.isEnabled)
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

// MARK: - Controller: double ⌘C → icon → translation

@MainActor
final class Controller: ObservableObject {
    @Published var isEnabled = true

    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastChangeDate = Date.distantPast
    private var timer: Timer?
    private let translator = Translator()
    private let popup = Popup()

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
    }

    private func tick() {
        let count = NSPasteboard.general.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        let now = Date()
        defer { lastChangeDate = now }
        guard isEnabled, now.timeIntervalSince(lastChangeDate) <= 0.4 else { return }
        lastChangeDate = .distantPast // avoid triple ⌘C firing twice
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        popup.showIcon { [weak self] in self?.translate(text) }
    }

    private var requestID = 0

    /// Last target language the user picked; survives restarts.
    private var lastTarget: Locale.Language? {
        get { UserDefaults.standard.string(forKey: "targetLanguage").map(Locale.Language.init(identifier:)) }
        set { UserDefaults.standard.set(newValue?.minimalIdentifier, forKey: "targetLanguage") }
    }

    private func translate(_ text: String, from chosenSource: Locale.Language? = nil, to chosenTarget: Locale.Language? = nil) {
        requestID += 1
        let id = requestID
        Task {
            let languages = await translator.supportedLanguages()
            let source = chosenSource ?? translator.detect(text)
            // English by default; once the user picks a target, that one is remembered.
            let candidate = chosenTarget ?? lastTarget ?? Locale.Language(identifier: "en")
            // Same as the source (e.g. English text) → let the user choose.
            let target = candidate.minimalIdentifier == source?.minimalIdentifier ? nil : candidate
            let show = { (state: ResultView.State) in
                guard id == self.requestID else { return } // a newer choice wins
                self.popup.showResult(ResultView(
                    state: state, source: source, target: target, languages: languages,
                    onSource: { self.translate(text, from: $0, to: target) },
                    onTarget: { self.lastTarget = $0; self.translate(text, from: source, to: $0) }))
            }
            guard let source else {
                return show(.message(String(localized: "Could not detect the language of the text.")))
            }
            guard let target else {
                return show(.message(String(localized: "Choose the language to translate into.")))
            }
            show(.loading)
            show(await translator.translate(text, from: source, to: target))
        }
    }
}

// MARK: - Translator

@MainActor
final class Translator {
    private var sessions: [String: TranslationSession] = [:]
    private var supported: [Locale.Language]?
    private let availability = LanguageAvailability()

    func detect(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }
    }

    /// Languages Apple Translation supports, sorted by name.
    func supportedLanguages() async -> [Locale.Language] {
        if supported == nil {
            supported = await availability.supportedLanguages
                .sorted { Self.name($0).localizedStandardCompare(Self.name($1)) == .orderedAscending }
        }
        return supported!
    }

    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async -> ResultView.State {
        let pair = "\(Self.name(source)) → \(Self.name(target))"
        switch await availability.status(from: source, to: target) {
        case .unsupported:
            return .message(String(localized: "Translation \(pair) is not supported."))
        case .supported:
            return .message(String(localized: "The \(pair) language model is not downloaded. Download it in System Settings → General → Language & Region → Translation Languages."))
        case .installed:
            let key = "\(source.minimalIdentifier)>\(target.minimalIdentifier)"
            let session = sessions[key] ?? TranslationSession(installedSource: source, target: target)
            sessions[key] = session
            do {
                return .translated(try await session.translate(text).targetText)
            } catch {
                return .message(error.localizedDescription)
            }
        @unknown default:
            return .message(String(localized: "Unknown language model status."))
        }
    }

    /// Language name in the system language, e.g. "English" / "английский".
    static func name(_ language: Locale.Language) -> String {
        let id = language.minimalIdentifier
        return Locale.current.localizedString(forIdentifier: id) ?? id
    }
}

// MARK: - Popup panels

final class KeyPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose?() } // Esc
}

@MainActor
final class Popup {
    private var panel: KeyPanel?
    private var clickMonitor: Any?
    private var hideTask: Task<Void, Never>?

    func showIcon(onTap: @escaping () -> Void) {
        let view = Button(action: onTap) {
            Image(systemName: "character.bubble.fill")
                .font(.system(size: 16))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Translate")
        show(view, key: false)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.close() }
        }
    }

    func showResult(_ view: ResultView) {
        var view = view
        view.onClose = { [weak self] in self?.close() }
        show(view, key: true)
    }

    private func show(_ content: some View, key: Bool) {
        // Once shown, the popup keeps its top-left corner; only the height changes.
        let topLeft = panel.map { NSPoint(x: $0.frame.minX, y: $0.frame.maxY) }
        close()

        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let hosting = NSHostingView(rootView: content
            .background(.regularMaterial, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5)))
        let size = hosting.fittingSize
        let p = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.nonactivatingPanel, .borderless],
                         backing: .buffered, defer: false)
        p.contentView = hosting
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.hasShadow = true
        p.onClose = { [weak self] in self?.close() }
        p.setFrameOrigin(position(for: size, topLeft: topLeft))
        key ? p.makeKeyAndOrderFront(nil) : p.orderFrontRegardless()
        panel = p

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { self.close() }
        }
    }

    /// Keep the given top-left corner, or place below-right of the mouse; clamp to the screen.
    private func position(for size: NSSize, topLeft: NSPoint?) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let corner = topLeft ?? NSPoint(x: mouse.x + 12, y: mouse.y - 12)
        let screen = NSScreen.screens.first { NSMouseInRect(corner, $0.frame, false) } ?? NSScreen.main
        var point = NSPoint(x: corner.x, y: corner.y - size.height)
        if let f = screen?.visibleFrame {
            point.x = min(max(point.x, f.minX), f.maxX - size.width)
            point.y = min(max(point.y, f.minY), f.maxY - size.height)
        }
        return point
    }

    func close() {
        hideTask?.cancel()
        hideTask = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Result view

struct ResultView: View {
    enum State { case loading, translated(String), message(String) }
    let state: State
    var source: Locale.Language?
    var target: Locale.Language?
    var languages: [Locale.Language] = []
    var onSource: (Locale.Language) -> Void = { _ in }
    var onTarget: (Locale.Language) -> Void = { _ in }
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !languages.isEmpty {
                HStack(spacing: 6) {
                    LanguagePicker(title: "Source language", selection: source,
                                   languages: languages, onChange: onSource)
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LanguagePicker(title: "Translate to", selection: target,
                                   languages: languages.filter { $0.minimalIdentifier != source?.minimalIdentifier },
                                   onChange: onTarget)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                Divider()
            }

            Group {
                switch state {
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 40)
                case .message(let text):
                    Label {
                        Text(text).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .translated(let text):
                    TranslatedText(text: text)
                }
            }
            .padding(14)

            if case .translated(let text) = state {
                Divider()
                HStack {
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        onClose()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 380)
    }
}

/// Short text grows with its content; long text scrolls inside a fixed height.
struct TranslatedText: View {
    let text: String

    var body: some View {
        let label = Text(text)
            .font(.system(size: 14))
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        if text.count > 600 {
            ScrollView { label }.frame(height: 300)
        } else {
            label
        }
    }
}

struct LanguagePicker: View {
    let title: LocalizedStringKey
    let selection: Locale.Language?
    let languages: [Locale.Language]
    let onChange: (Locale.Language) -> Void

    var body: some View {
        // Keep the current value selectable even if it is missing from the list.
        let ids = languages.map(\.minimalIdentifier)
        let extra = [selection?.minimalIdentifier].compactMap { $0 }.filter { !ids.contains($0) }
        Picker(title, selection: Binding(
            get: { selection?.minimalIdentifier ?? "" },
            set: { if !$0.isEmpty { onChange(Locale.Language(identifier: $0)) } })) {
            if selection == nil { Text(verbatim: "—").tag("") }
            ForEach(extra + ids, id: \.self) { id in
                Text(Translator.name(Locale.Language(identifier: id))).tag(id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .help(Text(title))
    }
}
