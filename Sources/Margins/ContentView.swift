import AppKit
import MarginsCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var sync = SyncController.shared
    @StateObject private var showLibraryPicker = Local(false)
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var intentWidth = Local<CGFloat>(340)

    private static let defaultIntentWidth: CGFloat = 340
    private static let dividerHitWidth: CGFloat = 11

    var body: some View {
        GeometryReader { geo in
            let maxIntent = max(220, geo.size.width - 360)
            let paneWidth = min(max(intentWidth.value, 220), maxIntent)
            HStack(spacing: 0) {
                IntentPane()
                    .environment(\.interfaceZoom, state.zoom)
                    .environment(\.uiFontFamily, state.effectiveFontPreferences.uiFont)
                    .uiFont(.body)
                    .frame(width: paneWidth)
                    .frame(width: state.zenMode ? 0 : paneWidth, alignment: .trailing)
                    .opacity(state.zenMode ? 0 : 1)
                    .clipped()
                    .disabled(state.zenMode || state.semanticZoomStop.rawValue < 100)
                    .allowsHitTesting(!state.zenMode && state.semanticZoomStop.rawValue == 100)
                    .accessibilityHidden(state.zenMode)
                if !state.zenMode {
                    Rectangle()
                        .fill(state.resolvedTheme.swiftUIColor("line"))
                        .frame(width: 1)
                        .transition(.opacity)
                }
                editorColumn
            }
            .overlay(alignment: .leading) {
                if !state.zenMode {
                    SplitDivider(
                        width: $intentWidth.value,
                        displayedWidth: paneWidth,
                        range: 220...maxIntent,
                        defaultWidth: Self.defaultIntentWidth,
                        hitWidth: Self.dividerHitWidth
                    )
                    .padding(.leading, max(0, paneWidth - (Self.dividerHitWidth - 1) / 2))
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: state.zenMode)
        }
        .sheet(isPresented: $showLibraryPicker.value) {
            LibraryPickerView(sync: sync, onDismiss: { showLibraryPicker.value = false })
        }
        .onReceive(NotificationCenter.default.publisher(for: .marginsOpenLibraryPicker)) { _ in
            if DocumentWindows.shared.keyState === state {
                showLibraryPicker.value = true
            }
        }
        .inspector(isPresented: $state.showHistory) {
            HistoryView()
                .environment(\.interfaceZoom, state.zoom)
                .environment(\.uiFontFamily, state.effectiveFontPreferences.uiFont)
                .uiFont(.body)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 720)
        }
        .navigationTitle(state.doc.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .toolbar(state.zenMode ? .hidden : .visible, for: .windowToolbar)
        .environment(\.marginsTheme, state.resolvedTheme)
        .onAppear { state.effectiveColorScheme = colorScheme == .dark ? .dark : .light }
        .onChange(of: colorScheme) { _, scheme in state.effectiveColorScheme = scheme == .dark ? .dark : .light }
        .alert("Margins", isPresented: Binding(get: { state.lastError != nil }, set: { if !$0 { state.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.lastError ?? "")
        }
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            if sync.showOnboarding {
                SyncOnboardingBanner(sync: sync)
            }
            if let entry = sync.entry(for: state.doc.id),
               entry.state == .conflict,
               let conflictName = entry.conflictFilename {
                ConflictBanner(
                    conflictFilename: conflictName,
                    onOpenConflict: {
                        let url = AppState.documentsFolder.appendingPathComponent(conflictName)
                        DocumentWindows.shared.open(url)
                    },
                    onDismiss: {
                        sync.clearConflict(for: state.doc.id)
                    }
                )
            }
            if let v = state.previewing {
                PreviewBanner(version: v)
                    .environment(\.interfaceZoom, state.zoom)
                    .environment(\.uiFontFamily, state.effectiveFontPreferences.uiFont)
            }
            if state.semanticZoomStop.rawValue < 100 {
                SemanticZoomBanner()
                    .environment(\.interfaceZoom, state.zoom)
                    .environment(\.uiFontFamily, state.effectiveFontPreferences.uiFont)
            }
            EditorView(bridge: state.editor)
        }
        .frame(minWidth: 360, maxWidth: .infinity)
        .layoutPriority(1)
    }

    private var subtitle: String {
        var parts: [String] = []
        if state.pending.total > 0 { parts.append("\(state.pending.total) pending") }
        if let v = state.doc.versions.last { parts.append("v\(v.number)") }
        parts.append(state.fileURL.deletingPathExtension().lastPathComponent)
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if state.busy { ProgressView().controlSize(.small).interfaceZoom(state.zoom) }
            SyncStatusPill(sync: sync).interfaceZoom(state.zoom)
            ProjectMenu().interfaceZoom(state.zoom)
            AgentMenu().interfaceZoom(state.zoom)
            SemanticZoomControl().interfaceZoom(state.zoom)
            Button {
                state.showOutline.toggle()
            } label: {
                Label("Outline", systemImage: state.showOutline ? "list.bullet.indent" : "list.bullet")
            }
            .help(state.showOutline ? "Hide outline (⌃⌘O)" : "Show outline (⌃⌘O)")
            .interfaceZoom(state.zoom)
            Button {
                state.toggleZenMode()
            } label: {
                Label("Zen Mode", systemImage: "rectangle.center.inset.filled")
            }
            .help("Zen Mode (⇧⌘F)")
            .interfaceZoom(state.zoom)
            Button {
                state.showHistory.toggle()
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .help("Version history (⌥⌘H)")
            .keyboardShortcut("h", modifiers: [.command, .option])
            .interfaceZoom(state.zoom)
        }
    }
}

/// Where the agent works: the author's project folder (so it can write code), or the document's scratch workspace.
struct ProjectMenu: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Menu {
            if let url = state.projectURL {
                Section(url.path) {
                    Button("Show in Finder") { state.revealWorkspace() }
                    Button("Open in Terminal") { state.openProjectInTerminal() }
                }
                Button("Change Project Folder…") { state.chooseProjectFolder() }
                Button("Stop Using Project Folder") { state.setProjectFolder(nil) }
            } else {
                if let name = state.projectName { Text("“\(name)” is missing") }
                Button("Choose Project Folder…") { state.chooseProjectFolder() }
                Text("Pick a folder (e.g. a code repo) and the agent can write code, run builds and edit files there.")
            }
            let recent = state.recentProjectFolders
            if !recent.isEmpty {
                Section("Recent Projects") {
                    ForEach(recent, id: \.self) { url in
                        Button {
                            state.selectProjectFolder(url)
                        } label: {
                            Label(ProjectFolderStore.displayLabel(for: url, among: recent), systemImage: "folder")
                        }
                    }
                    Button("Clear Recent Projects") { state.clearRecentProjectFolders() }
                }
            }
            Divider()
            Text(hint)
        } label: {
            Label(state.projectName ?? "No project", systemImage: state.projectURL != nil ? "folder.fill" : "folder")
                .labelStyle(.titleAndIcon)
        }
        .help(state.projectURL.map { "Agent works in \($0.path)" } ?? "Choose a project folder for the agent to work in")
    }

    private var hint: String {
        switch state.toolPolicy {
        case .full: return "Agent tools: Full — can change files and run commands."
        case .unrestricted: return "Agent tools: Unrestricted — can change anything on this Mac."
        case .research: return "Agent tools: Research — read-only (Copilot asks before changes)."
        case .off: return "Agent tools: Off — the agent only edits the document."
        }
    }
}

struct PreviewBanner: View {
    @EnvironmentObject var state: AppState
    @Environment(\.marginsTheme) private var theme
    let version: Version

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
            Text("Viewing **v\(version.number)** — \(version.slug)").lineLimit(1)
            Text(version.createdAt, style: .relative).foregroundStyle(.secondary) + Text(" ago").foregroundStyle(.secondary)
            Spacer()
            Button("Return to latest") { state.returnToLatest() }
            Button("Restore this version") { state.restore(version) }
                .buttonStyle(.borderedProminent)
        }
        .uiFont(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.swiftUIColor("threadBg"))
        .overlay(Divider(), alignment: .bottom)
    }
}

private struct SplitDivider: View {
    @Binding var width: CGFloat
    let displayedWidth: CGFloat
    let range: ClosedRange<CGFloat>
    let defaultWidth: CGFloat
    let hitWidth: CGFloat
    @Environment(\.marginsTheme) private var theme
    @StateObject private var isHovering = Local(false)
    @StateObject private var isDragging = Local(false)

    private var isActive: Bool { isHovering.value || isDragging.value }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isActive ? theme.swiftUIColor("accent").opacity(isDragging.value ? 0.85 : 0.45) : .clear)
                .frame(width: isActive ? 3 : 1)
            Capsule()
                .fill(
                    isActive
                        ? theme.swiftUIColor("accent").opacity(isDragging.value ? 1.0 : 0.85)
                        : theme.swiftUIColor("mutedInk").opacity(0.35)
                )
                .frame(width: isActive ? 4 : 3, height: isActive ? 36 : 28)
            SplitResizeHandle(
                width: displayedWidth,
                range: range,
                defaultWidth: defaultWidth,
                onWidthChange: { width = $0 },
                onHoverChange: { isHovering.value = $0 },
                onDragChange: { isDragging.value = $0 }
            )
        }
        .frame(width: hitWidth)
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }
}

/// AppKit-backed resize hit area so the divider sits above WKWebView and tracks cursor/drag reliably.
private struct SplitResizeHandle: NSViewRepresentable {
    let width: CGFloat
    let range: ClosedRange<CGFloat>
    let defaultWidth: CGFloat
    let onWidthChange: (CGFloat) -> Void
    let onHoverChange: (Bool) -> Void
    let onDragChange: (Bool) -> Void

    func makeNSView(context: Context) -> SplitResizeNSView {
        let view = SplitResizeNSView()
        sync(view)
        return view
    }

    func updateNSView(_ nsView: SplitResizeNSView, context: Context) {
        sync(nsView)
    }

    private func sync(_ view: SplitResizeNSView) {
        view.currentWidth = width
        view.range = range
        view.defaultWidth = defaultWidth
        view.onWidthChange = onWidthChange
        view.onHoverChange = onHoverChange
        view.onDragChange = onDragChange
    }
}

private final class SplitResizeNSView: NSView {
    var currentWidth: CGFloat = 340
    var range: ClosedRange<CGFloat> = 220...600
    var defaultWidth: CGFloat = 340
    var onWidthChange: ((CGFloat) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onDragChange: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var dragStartScreenX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0
    private var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        if !isDragging { onHoverChange?(false) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let clamped = min(max(defaultWidth, range.lowerBound), range.upperBound)
            currentWidth = clamped
            onWidthChange?(clamped)
            return
        }
        dragStartScreenX = NSEvent.mouseLocation.x
        dragStartWidth = currentWidth
        isDragging = true
        onDragChange?(true)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let proposed = dragStartWidth + (NSEvent.mouseLocation.x - dragStartScreenX)
        let clamped = min(max(proposed, range.lowerBound), range.upperBound)
        currentWidth = clamped
        onWidthChange?(clamped)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onDragChange?(false)
        let point = convert(event.locationInWindow, from: nil)
        onHoverChange?(bounds.contains(point))
        window?.invalidateCursorRects(for: self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            isDragging = false
            onDragChange?(false)
            onHoverChange?(false)
        }
    }
}
