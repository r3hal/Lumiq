import SwiftUI

@MainActor final class CloudCompositionScanModel: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message = "Local AI Guide stays on while a scan runs."
    private let service: (any CloudCompositionService)?
    private var task: Task<Void,Never>?
    private var ticket: CloudScanTicket?
    var configured: Bool { service != nil }
    init(service:(any CloudCompositionService)? = GeminiCloudConfiguration.localDeveloperService()) { self.service = service }
    func scan(camera:CameraController) {
        guard !busy, let service else { message = CloudCompositionError.notConfigured.message; return }
        guard let ticket = camera.beginCloudScan() else { message = CloudCompositionError.unsupportedSource.message; return }
        self.ticket = ticket
        busy = true; message = "Preparing one camera frame…"
        task = Task { [weak self] in
            defer { self?.busy = false; self?.task = nil }
            do {
                let capture = try await camera.captureCloudScan(ticket:ticket)
                try Task.checkCancellation()
                self?.message = "Google is analyzing this frame. Local guidance continues."
                let result = try await service.scan(capture)
                try Task.checkCancellation()
                try await camera.applyCloudComposition(result,capture:capture)
                self?.message = "Composition locked. Return to the camera for local guidance."
            } catch {
                camera.cancelCloudScan(requestID:ticket.id)
                self?.message = (error as? CloudCompositionError ?? (error is CancellationError ? .cancelled : .serviceUnavailable)).message
            }
        }
    }
    func cancel(camera:CameraController) { task?.cancel(); if let ticket { camera.cancelCloudScan(requestID:ticket.id) }; message = CloudCompositionError.cancelled.message }
}

struct CloudCompositionScanView: View {
    @ObservedObject var camera: CameraController
    @StateObject private var model = CloudCompositionScanModel()
    @AppStorage("experimentalCloudCompositionDisclosure.v1") private var disclosed = false
    @State private var acknowledge = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Experimental Cloud AI Scan") {
                    Text("Send one compressed camera frame to Google for a composition suggestion. This does not stream your video or upload your photo library.")
                    Text("Tracking, arrows, autofocus, zoom safety, READY verification and the shutter stay on your iPhone.")
                    Text("Google processes the frame under its Gemini API terms. Data handling varies by account and region. Avoid sensitive scenes.").font(.footnote)
                    Link("Google Gemini data terms",destination:URL(string:"https://ai.google.dev/gemini-api/terms")!)
                    if !disclosed { Toggle("I understand that one frame will be processed by Google",isOn:$acknowledge) }
                }
                Section {
                    if !model.configured { Text(CloudCompositionError.notConfigured.message) }
                    Button(model.busy ? "Analyzing one frame…" : "Send one frame to Google") {
                        disclosed = true; model.scan(camera:camera)
                    }.disabled(model.busy || !model.configured || (!disclosed && !acknowledge))
                    if model.busy { Button("Cancel scan",role:.cancel) { model.cancel(camera:camera) } }
                    Text(model.message).font(.footnote)
                    Text(camera.cloudCompositionStatus).font(.footnote)
                }
                Section("Composition lock") {
                    Text("A verified suggestion stays selected while local observations remain valid. New attractive candidates do not replace it. Manual zoom keeps priority; untracked features never create directional arrows.").font(.footnote)
                    Button("Use local composition guidance") { model.cancel(camera:camera); camera.unlockCloudComposition(); dismiss() }
                }
            }
            .navigationTitle("Cloud Composition")
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
            .onDisappear { model.cancel(camera:camera) }
        }
    }
}
