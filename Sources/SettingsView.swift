import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Default ⌃⌥J — the key the owner already uses with Markie.
    static let toggleShpora = Self("toggleShpora", default: .init(.j, modifiers: [.control, .option]))
    /// Window-only keys: matched in the window's key monitor, never registered globally.
    static let toggleSplitPane = Self("toggleSplitPane", default: .init(.d, modifiers: [.command]))
    static let openSettings = Self("openSettings", default: .init(.comma, modifiers: [.command]))
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        // Tabs (owner 09.11.2026: «настройки, наверное, разбить на несколько вкладок»).
        TabView {
            // Order per owner 09.11.2026: General, Shortcuts, Look, About.
            generalTab.tabItem { Label(String(localized: "General"), systemImage: "gearshape") }
            keysTab.tabItem { Label(String(localized: "Shortcuts"), systemImage: "command") }
            lookTab.tabItem { Label(String(localized: "Look"), systemImage: "paintbrush") }
            aboutTab.tabItem { Label(String(localized: "About"), systemImage: "info.circle") }
        }
        .frame(width: 600, height: 470)
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle(String(localized: "Open at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle(String(localized: "Show icon in the Dock"), isOn: $model.showInDock)
                Toggle(String(localized: "Show icon in the menu bar"), isOn: $model.showInMenuBar)
            } footer: {
                Text("With both icons off, open Shpora again from Applications or Spotlight to bring the window back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            filesSection
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Version"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                Text("Everything you type is saved to the file automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(String(localized: "Updates")) {
                // Laid in, not wired: there is no place yet where new versions are published.
                Toggle(String(localized: "Check for updates automatically"), isOn: $model.autoCheckUpdates)
                Button(String(localized: "Check Now")) {}
                    .disabled(true)
                Text("Updates will work once there is a place to publish new versions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Owner 09.11.2026: «сделать, чтобы был некий предпросмотр, и человек понимал, как это будет
    /// выглядеть». Each choice is a live sample: the real material over a busy picture.
    private var lookTab: some View {
        Form {
            Section(String(localized: "Background")) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
                    ForEach(WindowBackground.allCases) { style in
                        BackgroundTile(style: style, selected: model.background == style)
                            .onTapGesture { model.background = style }
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                HStack(spacing: 12) {
                    Text(String(localized: "Text size"))
                    Slider(value: $model.fontSize, in: 11...28, step: 1) { EmptyView() }
                    Text("\(Int(model.fontSize)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var keysTab: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder(String(localized: "Show / hide Shpora"), name: .toggleShpora)
                KeyboardShortcuts.Recorder(String(localized: "Open / close the second pane"), name: .toggleSplitPane)
                KeyboardShortcuts.Recorder(String(localized: "Open settings"), name: .openSettings)
            } footer: {
                Text("The first one works everywhere. The others work only while the Shpora window is in focus.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(String(localized: "Keys in the window")) {
                KeyRow(keys: "⌘W", text: String(localized: "Close the second pane"))
                KeyRow(keys: "⌘T", text: String(localized: "Insert a timestamp line"))
                KeyRow(keys: "⌘O", text: String(localized: "Open the file in its default app"))
                KeyRow(keys: "⌘[  ⌘]", text: String(localized: "Go to the left / right pane"))
                KeyRow(keys: "⌘+  ⌘−  ⌘0", text: String(localized: "Text size"))
                KeyRow(keys: "Esc", text: String(localized: "Hide the window"))
            }
        }
        .formStyle(.grouped)
    }

    private var filesSection: some View {
            Section(String(localized: "Files")) {
                if model.files.isEmpty {
                    Text("No files yet").foregroundStyle(.secondary)
                }
                ForEach(model.files, id: \.self) { url in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                            Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless)
                            .help(String(localized: "Show in Finder"))
                        Button {
                            model.remove(url)
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help(String(localized: "Remove from list (the file stays on disk)"))
                    }
                }
                HStack {
                    Button(String(localized: "Add File…")) { model.pickFile(for: model.activeSide) }
                    Button(String(localized: "New File…")) { model.newFile(for: model.activeSide) }
                }
            }
    }
}

/// A small live sample of one window background: the real material over a busy picture.
private struct BackgroundTile: View {
    let style: WindowBackground
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                LinearGradient(colors: [.blue, .purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                // Busy text behind the sample: without it glass and frosted look the same.
                Text("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris.")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(6)
                MaterialSample(style: style)
                    // The sample text lives inside the card, padded on both sides, so it can't run
                    // past the card's edge (it did with a free-floating label).
                    .overlay(alignment: .leading) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: "Lorem ipsum")
                            Text(verbatim: "dolor sit amet")
                        }
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 14).padding(.vertical, 18)
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 3 : 1))
            Text(style.title).font(.callout).foregroundStyle(selected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
    }
}

/// The same backdrop views the window uses, so the sample is what the window will really look like.
private struct MaterialSample: NSViewRepresentable {
    let style: WindowBackground
    func makeNSView(context: Context) -> NSView { WindowBackground.makeBackdrop(style, inWindow: true) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct KeyRow: View {
    let keys: String
    let text: String
    var body: some View {
        HStack {
            Text(text)
            Spacer()
            Text(keys).font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
        }
    }
}
