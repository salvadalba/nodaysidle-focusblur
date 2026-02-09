import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage("intensity") private var intensity: Double = 0.7
    @AppStorage("grayscale") private var grayscale: Bool = false
    @AppStorage("tintEnabled") private var tintEnabled: Bool = false
    @AppStorage("tintR") private var tintR: Double = 0.2
    @AppStorage("tintG") private var tintG: Double = 0.4
    @AppStorage("tintB") private var tintB: Double = 0.9
    @AppStorage("tintOpacity") private var tintOpacity: Double = 0.15
    @AppStorage("loginItem") private var loginItem: Bool = false
    @AppStorage("excludedJSON") private var excludedJSON: String = "[]"

    @State private var showAppPicker = false

    private var tintColor: Binding<Color> {
        Binding(
            get: { Color(red: tintR, green: tintG, blue: tintB) },
            set: { newColor in
                if let c = NSColor(newColor).usingColorSpace(.sRGB) {
                    tintR = c.redComponent
                    tintG = c.greenComponent
                    tintB = c.blueComponent
                }
            }
        )
    }

    private var excludedIDs: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(excludedJSON.utf8))) ?? [] }
    }

    private func setExcluded(_ ids: [String]) {
        excludedJSON = (try? String(data: JSONEncoder().encode(ids), encoding: .utf8)) ?? "[]"
    }

    var body: some View {
        Form {
            // MARK: - Blur
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Blur Intensity")
                        Spacer()
                        Text("\(Int(intensity * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $intensity, in: 0.05...1.0, step: 0.05)
                }
            } header: {
                Label("Blur", systemImage: "aqi.medium")
            }

            // MARK: - Effects
            Section {
                Toggle("Grayscale background", isOn: $grayscale)

                Toggle("Color tint overlay", isOn: $tintEnabled)

                if tintEnabled {
                    HStack {
                        ColorPicker("Tint color", selection: tintColor, supportsOpacity: false)
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Tint opacity")
                            Spacer()
                            Text("\(Int(tintOpacity * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $tintOpacity, in: 0.05...0.5, step: 0.05)
                    }
                }
            } header: {
                Label("Effects", systemImage: "sparkles")
            }

            // MARK: - Excluded Apps
            Section {
                if excludedIDs.isEmpty {
                    Text("No excluded apps")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(excludedIDs, id: \.self) { bundleID in
                        HStack {
                            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                }
                                Text(app.localizedName ?? bundleID)
                            } else {
                                Image(systemName: "app")
                                    .frame(width: 20, height: 20)
                                Text(bundleID)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                var ids = excludedIDs
                                ids.removeAll { $0 == bundleID }
                                setExcluded(ids)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Button("Add App…") { showAppPicker = true }
                    .sheet(isPresented: $showAppPicker) {
                        AppPickerSheet(excludedIDs: excludedIDs) { bundleID in
                            var ids = excludedIDs
                            if !ids.contains(bundleID) {
                                ids.append(bundleID)
                                setExcluded(ids)
                            }
                            showAppPicker = false
                        } onCancel: {
                            showAppPicker = false
                        }
                    }
            } header: {
                Label("Excluded Apps", systemImage: "eye.slash")
            }

            // MARK: - General
            Section {
                Toggle("Launch at login", isOn: $loginItem)
                    .onChange(of: loginItem) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            NSLog("FocusBlur: Login item error: \(error)")
                        }
                    }
            } header: {
                Label("General", systemImage: "gearshape")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 520)
    }
}

// MARK: - App Picker Sheet

struct AppPickerSheet: View {
    let excludedIDs: [String]
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    private var runningApps: [(name: String, bundleID: String, icon: NSImage)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { !excludedIDs.contains($0.bundleIdentifier ?? "") }
            .compactMap { app in
                guard let name = app.localizedName, let id = app.bundleIdentifier else { return nil }
                return (name: name, bundleID: id, icon: app.icon ?? NSImage())
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Select an app to exclude")
                .font(.headline)
                .padding()

            List(runningApps, id: \.bundleID) { app in
                Button {
                    onSelect(app.bundleID)
                } label: {
                    HStack {
                        Image(nsImage: app.icon)
                            .resizable()
                            .frame(width: 24, height: 24)
                        Text(app.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 200)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 320, height: 350)
    }
}

// MARK: - Settings Window Helper

final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView()
        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hosting)
        w.title = "FocusBlur Preferences"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 400, height: 520))
        w.center()
        w.isReleasedWhenClosed = false
        // Float above blur overlays so settings are always visible
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
