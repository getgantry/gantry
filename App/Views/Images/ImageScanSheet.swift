import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore
import DockerKit

/// A scan sheet request: one model per opened sheet.
struct ImageScanRequest: Identifiable {
    let id = UUID()
    let imageName: String
    let model: ImageScanModel

    @MainActor
    init?(image: ImageSummary, session: HostSession) {
        guard let model = session.makeImageScanModel(for: image) else { return nil }
        self.imageName = image.displayName
        self.model = model
        model.startDetection()
    }
}

extension View {
    /// Presents the scan sheet of `request`.
    func imageScanSheet(_ request: Binding<ImageScanRequest?>) -> some View {
        sheet(item: Binding(
            get: { request.wrappedValue },
            set: { new in
                // Close the old model here too: a hidden window can skip onDisappear.
                if let old = request.wrappedValue, old.id != new?.id { old.model.close() }
                request.wrappedValue = new
            }
        )) { request in
            ImageScanSheet(model: request.model, imageName: request.imageName)
        }
    }
}

/// Runs Trivy or Grype on one image and shows the findings by severity.
struct ImageScanSheet: View {
    @Bindable var model: ImageScanModel
    let imageName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ImageScanHeader(model: model, imageName: imageName)
            ImageScanContent(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            SBOMStatusLine(model: model)
            ImageScanFooter(model: model, imageName: imageName) { dismiss() }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 700, minHeight: 480, idealHeight: 560)
        .onDisappear { model.close() }
    }
}

// MARK: - Header and footer

private struct ImageScanHeader: View {
    @Bindable var model: ImageScanModel
    let imageName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan for Vulnerabilities")
                        .font(.title2.weight(.bold))
                    Text(imageName)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                if model.scanners.count > 1 {
                    Picker("Scanner", selection: $model.selectedKind) {
                        ForEach(model.scanners) { scanner in
                            Text(scanner.kind.displayName).tag(Optional(scanner.kind))
                        }
                    }
                    .fixedSize()
                    .disabled(model.isBusy)
                }
            }
            if model.plan.scansRegistryCopy {
                Label(
                    "This host is remote, so Gantry scans the registry copy of this tag. It can differ from the image on the host.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ImageScanFooter: View {
    let model: ImageScanModel
    let imageName: String
    let close: () -> Void

    var body: some View {
        HStack {
            SBOMExportMenu(model: model, imageName: imageName)
            Spacer()
            if model.isBusy {
                Button("Stop", role: .cancel) { model.cancel() }
                    .help("Stop the scan and remove its temporary files")
            }
            Button("Close") { close() }
                .keyboardShortcut(.cancelAction)
            if canScan {
                Button(hasRun ? "Scan Again" : "Scan") { model.scan() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy)
            }
        }
    }

    private var canScan: Bool {
        guard let scanner = model.selectedScanner, scanner.isSupported else { return false }
        switch model.state {
        case .detecting, .noScanner: return false
        default: return true
        }
    }

    private var hasRun: Bool {
        switch model.state {
        case .finished, .failed, .cancelled: true
        default: false
        }
    }
}

// MARK: - Content

private struct ImageScanContent: View {
    let model: ImageScanModel

    var body: some View {
        switch model.state {
        case .detecting:
            ProgressView("Looking for Trivy and Grype…")
        case .noScanner:
            ScannerInstallHelp(model: model)
        case .ready:
            ReadyToScanView(scanner: model.selectedScanner)
        case .running(let step, let startedAt):
            ScanProgressView(
                step: step, startedAt: startedAt, scanner: model.selectedScanner?.kind.displayName ?? ""
            )
        case .finished(let report):
            ScanFindingsView(report: report)
        case .failed(let message):
            ScanFailedView(message: message)
        case .cancelled:
            ContentUnavailableView(
                "Scan Cancelled",
                systemImage: "xmark.circle",
                description: Text("Gantry stopped the scan and removed its temporary files.")
            )
        }
    }
}

private struct ReadyToScanView: View {
    let scanner: InstalledScanner?

    var body: some View {
        if let scanner, !scanner.isSupported {
            ContentUnavailableView {
                Label("Update \(scanner.kind.displayName)", systemImage: "arrow.up.circle")
            } description: {
                Text("\(scanner.kind.displayName) \(scanner.version ?? "") is too old. Gantry needs version \(scanner.kind.minimumVersion) or later.")
            } actions: {
                CommandText("brew upgrade \(scanner.kind.rawValue)")
            }
        } else {
            ContentUnavailableView(
                "Ready to Scan",
                systemImage: "checkmark.shield",
                description: Text("Gantry exports the image to a temporary folder and runs \(scanner?.kind.displayName ?? ""). The first scan downloads the vulnerability database, which can take some minutes.")
            )
        }
    }
}

private struct ScanProgressView: View {
    let step: ImageScanModel.Step
    let startedAt: Date
    let scanner: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(Duration.seconds(max(0, context.date.timeIntervalSince(startedAt))).formatted(.time(pattern: .minuteSecond)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if step == .scanning {
                Text("The first scan downloads the vulnerability database. This can take some minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    private var title: String {
        switch step {
        case .exporting: String(localized: "Exporting the image…")
        case .unpacking: String(localized: "Unpacking the image…")
        case .scanning: String(localized: "Scanning with \(scanner)…")
        }
    }
}

private struct ScanFailedView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Scan Failed", systemImage: "exclamationmark.triangle")
        } description: {
            ScrollView {
                Text(message)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        }
    }
}

// MARK: - Install help

private struct ScannerInstallHelp: View {
    let model: ImageScanModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shield.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No Scanner Installed")
                .font(.title3.weight(.semibold))
            Text("Gantry scans images with Trivy or Grype. Gantry does not install them. Install one with Homebrew, then choose Check Again.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(ScannerKind.allCases) { kind in
                    GridRow {
                        Text(kind.displayName).font(.headline)
                        CommandText(kind.installCommand)
                        Link("Install Page", destination: kind.installPageURL)
                    }
                }
            }
            Button("Check Again") { Task { await model.detect() } }
        }
        .padding()
    }
}

/// A shell command the user can select or copy.
private struct CommandText: View {
    let command: String

    init(_ command: String) { self.command = command }

    var body: some View {
        HStack(spacing: 6) {
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Label("Copy Command", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Copy Command")
        }
    }
}

// MARK: - SBOM

private struct SBOMExportMenu: View {
    let model: ImageScanModel
    let imageName: String

    var body: some View {
        Menu {
            ForEach(SBOMFormat.allCases) { format in
                Button(format.displayName) { export(format) }
                    .disabled(!model.sbomFormats.contains(format))
            }
            if model.selectedScanner?.kind == .grype {
                Divider()
                Text("SPDX needs Trivy.")
            }
        } label: {
            Label("Export SBOM", systemImage: "square.and.arrow.up")
        }
        .fixedSize()
        .disabled(!canExport)
        .help("Save a software bill of materials of the image")
    }

    private var canExport: Bool {
        guard !model.isBusy, let scanner = model.selectedScanner, scanner.isSupported else { return false }
        switch model.state {
        case .detecting, .noScanner: return false
        default: return true
        }
    }

    private func export(_ format: SBOMFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.fileName(for: imageName) + format.fileSuffix
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportSBOM(format, to: url.path)
    }

    /// `ghcr.io/org/app:1.2` becomes `app-1.2`.
    static func fileName(for reference: String) -> String {
        let last = reference.split(separator: "/").last.map(String.init) ?? reference
        let cleaned = last.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "-")
        return cleaned.isEmpty ? "image" : cleaned
    }
}

private struct SBOMStatusLine: View {
    let model: ImageScanModel

    var body: some View {
        switch model.sbomState {
        case .idle:
            EmptyView()
        case .running(let format, _):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing the \(format.displayName) SBOM…").font(.callout)
            }
        case .saved(let path):
            HStack(spacing: 8) {
                Label("Saved \(URL(fileURLWithPath: path).lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .buttonStyle(.link)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}
