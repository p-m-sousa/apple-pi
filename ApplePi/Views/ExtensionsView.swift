import AppKit
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import WebKit

struct ExtensionsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case discover = "Discover"
        case installed = "Installed"
        case development = "Local Development"
        var id: String { rawValue }
    }

    @Bindable var model: AppModel
    @State private var tab: Tab = .discover
    @State private var installSource = ""
    @State private var scope: ApplePiPackageScope = .global
    @State private var sourcePendingConfirmation: String?
    @State private var showFolderImporter = false
    @State private var catalogLoadState: PiPackageCatalogLoadState = .loading
    @State private var catalogReloadID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                switch tab {
                case .discover:
                    discover
                case .installed:
                    installed
                case .development:
                    development
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Install Pi package?",
            isPresented: installConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Install") {
                guard let source = sourcePendingConfirmation else { return }
                Task { await model.installPackage(source: source, scope: scope) }
                installSource = ""
                sourcePendingConfirmation = nil
            }
            Button("Cancel", role: .cancel) { sourcePendingConfirmation = nil }
        } message: {
            Text("Pi packages run with your filesystem and network authority. Only install code you trust.")
        }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task { await model.installLocalPackage(url, scope: scope) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extensions")
                        .font(.title2.weight(.semibold))
                    Text("Portable Pi packages and resources")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 360)
                .accessibilityIdentifier("applepi.extensions.section-picker")
            }

            DisclosureGroup {
                Text("Pi packages are executable code, not sandboxed app plug-ins. Project resources use Pi's own trust decisions, including inherited parent-directory decisions. ApplePi does not add a separate permissions layer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
            } label: {
                Label("Install only packages you trust", systemImage: "exclamationmark.shield")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ApplePiPalette.terracotta)
            }
        }
        .padding(18)
    }

    private var discover: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                TextField("Package source", text: $installSource, prompt: Text("npm package, Git URL, or local path"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { proposeInstall(installSource) }

                scopePicker

                Button("Install") { proposeInstall(installSource) }
                    .buttonStyle(.borderedProminent)
                    .disabled(validatedSource(installSource) == nil)
            }
            .padding(12)
            .background(.bar)

            ZStack {
                // The web process exists only while Discover is selected.
                PiPackageCatalogWebView(
                    onInstallCommand: { command in
                        if let source = Self.source(fromExactInstallCommand: command) {
                            installSource = source
                        }
                    },
                    onLoadStateChange: { state in
                        catalogLoadState = state
                    }
                )
                .id(catalogReloadID)

                switch catalogLoadState {
                case .loading:
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Opening pi.dev/packages…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)

                case let .failed(detail):
                    ContentUnavailableView {
                        Label("Package catalog unavailable", systemImage: "network.slash")
                    } description: {
                        Text(detail)
                    } actions: {
                        HStack {
                            Button("Try Again") {
                                catalogLoadState = .loading
                                catalogReloadID = UUID()
                            }
                            Button("Open in Browser") {
                                NSWorkspace.shared.open(PiPackageCatalogWebView.Coordinator.catalogURL)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)

                case .loaded:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var installed: some View {
        Group {
            if model.packages.isEmpty {
                ContentUnavailableView {
                    Label("No packages found", systemImage: "shippingbox")
                } description: {
                    Text("Install from the Pi catalog or add a local development folder.")
                }
            } else {
                List {
                    ForEach(ApplePiPackageScope.allCases) { scope in
                        let resources = model.packages.filter { $0.scope == scope }
                        if !resources.isEmpty {
                            Section(scope.title) {
                                ForEach(resources) { package in
                                    PackageResourceRow(model: model, package: package)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var development: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ApplePiPanel {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "hammer")
                            .font(.title2)
                            .foregroundStyle(ApplePiPalette.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Develop a Pi extension locally")
                                .font(.headline)
                            Text("Install a folder, then ApplePi can show Pi's load errors, watch for changes, and request a safe reload through the bridge.")
                                .foregroundStyle(.secondary)
                            HStack {
                                scopePicker
                                Button("Choose Folder…") { showFolderImporter = true }
                                    .buttonStyle(.borderedProminent)
                            }
                            .padding(.top, 5)
                        }
                    }
                }

                ForEach(model.packages.filter { $0.localURL != nil }) { package in
                    ApplePiPanel {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(package.name).font(.headline)
                                    Text(package.localURL?.path ?? package.packageSource)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if let detail = package.statusDetail {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(detail.localizedCaseInsensitiveContains("error") ? .red : .secondary)
                                }
                            }
                            HStack {
                                Button("Reload") { Task { await model.reloadLocalPackage(package) } }
                                if let url = package.localURL {
                                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    Button("Open in Editor") { NSWorkspace.shared.open(url) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $scope) {
            ForEach(ApplePiPackageScope.allCases) { scope in
                Text(scope.title).tag(scope)
                    .disabled(scope == .project && model.selectedProjectURL == nil)
            }
        }
        .frame(width: 112)
    }

    private func proposeInstall(_ input: String) {
        guard let source = validatedSource(input) else { return }
        sourcePendingConfirmation = source
    }

    private func validatedSource(_ input: String) -> String? {
        let source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty,
              !source.hasPrefix("-"),
              !source.contains(where: { $0.isNewline || $0 == ";" || $0 == "|" || $0 == "&" }) else { return nil }
        return source
    }

    private var installConfirmationPresented: Binding<Bool> {
        Binding(
            get: { sourcePendingConfirmation != nil },
            set: { if !$0 { sourcePendingConfirmation = nil } }
        )
    }

    static func source(fromExactInstallCommand command: String) -> String? {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard command.hasPrefix("pi install ") else { return nil }
        let source = String(command.dropFirst("pi install ".count))
        guard !source.isEmpty,
              !source.contains(where: { $0.isWhitespace || $0 == ";" || $0 == "|" || $0 == "&" }),
              !source.hasPrefix("-") else { return nil }
        return source
    }
}

private struct PackageResourceRow: View {
    let model: AppModel
    let package: ApplePiPackageResource

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(package.isEnabled ? ApplePiPalette.accent : .secondary)
                .frame(width: 19)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.name)
                    if let version = package.version {
                        Text(version).font(.caption).foregroundStyle(.secondary)
                    }
                    if package.hasUpdate {
                        Text("Update")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(ApplePiPalette.sunkissed.opacity(0.24), in: Capsule())
                    }
                }
                Text(package.statusDetail ?? package.packageSource)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if package.isToggleable {
                Toggle("Enabled", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel("Enable \(package.name)")
            } else {
                Text("Package")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("Installed package")
            }
            if package.hasUpdate {
                Button("Update") { Task { await model.updatePackage(package) } }
                    .controlSize(.small)
            }
            Menu {
                if let url = package.localURL {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Remove", role: .destructive) { Task { await model.removePackage(package) } }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 3)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { package.isEnabled },
            set: { enabled in Task { await model.setPackage(package, enabled: enabled) } }
        )
    }

    private var icon: String {
        switch package.kind {
        case .extensionResource: "puzzlepiece.extension"
        case .skill: "wand.and.stars"
        case .prompt: "text.bubble"
        case .theme: "paintpalette"
        }
    }
}

private enum PiPackageCatalogLoadState: Equatable {
    case loading
    case loaded
    case failed(String)
}

private struct PiPackageCatalogWebView: NSViewRepresentable {
    let onInstallCommand: (String) -> Void
    let onLoadStateChange: (PiPackageCatalogLoadState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onInstallCommand: onInstallCommand,
            onLoadStateChange: onLoadStateChange
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.messageName)
        controller.addUserScript(WKUserScript(
            source: Coordinator.installCaptureScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .windowBackgroundColor
        webView.setAccessibilityLabel("Pi package catalog")
        webView.setAccessibilityIdentifier("applepi.extensions.catalog")
        webView.load(URLRequest(
            url: Coordinator.catalogURL,
            cachePolicy: .reloadIgnoringLocalCacheData
        ))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onInstallCommand = onInstallCommand
        context.coordinator.onLoadStateChange = onLoadStateChange
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageName)
        webView.configuration.userContentController.removeAllUserScripts()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let catalogURL = URL(string: "https://pi.dev/packages")!
        static let messageName = "applePiInstall"
        static let installCaptureScript = #"""
        (() => {
          document.addEventListener('click', event => {
            const node = event.target.closest('button, a, code, pre');
            if (!node) return;
            const text = (node.innerText || node.textContent || '').trim();
            if (/^pi install [^\s;|&]+$/.test(text)) {
              window.webkit.messageHandlers.applePiInstall.postMessage(text);
              event.preventDefault();
            }
          }, true);
        })();
        """#

        var onInstallCommand: (String) -> Void
        var onLoadStateChange: (PiPackageCatalogLoadState) -> Void

        init(
            onInstallCommand: @escaping (String) -> Void,
            onLoadStateChange: @escaping (PiPackageCatalogLoadState) -> Void
        ) {
            self.onInstallCommand = onInstallCommand
            self.onLoadStateChange = onLoadStateChange
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadStateChange(.loading)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadStateChange(.loaded)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            onLoadStateChange(.failed(error.localizedDescription))
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            onLoadStateChange(.failed(error.localizedDescription))
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.messageName, let command = message.body as? String else { return }
            onInstallCommand(command)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else {
                return .cancel
            }

            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            if isMainFrame, Self.isCatalogURL(url) {
                return .allow
            }

            // Keep embedded frames on the same origin too. Subresources are not
            // navigation actions, so this does not block the catalog's styles/assets.
            if !isMainFrame, Self.isPiOrigin(url) {
                return .allow
            }

            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }

        private static func isCatalogURL(_ url: URL) -> Bool {
            guard isPiOrigin(url), url.user == nil, url.password == nil else { return false }
            return url.path == "/packages" || url.path == "/packages/"
        }

        private static func isPiOrigin(_ url: URL) -> Bool {
            guard url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "pi.dev" else { return false }
            return url.port == nil || url.port == 443
        }
    }
}
