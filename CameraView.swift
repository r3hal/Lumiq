import SwiftUI

struct CameraView: View {
    @StateObject private var camera = CameraController()
    @EnvironmentObject private var library: PhotoLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var demo = false
    @State private var grid = true
    @State private var guide = true
    @State private var mode: CompositionMode = .thirds
    @State private var saving = false
    @State private var saved = false
    @State private var showHelp = false
    @State private var demoSubject = UnitPoint2D(x: 0.55, y: 0.43)
    @State private var demoEngine = CompositionEngine()
    @State private var demoReading = CompositionReading()
    @State private var demoReset = UUID()

    private var reading: CompositionReading { demo ? demoReading : camera.reading }
    private var canShoot: Bool { (demo || camera.isRunning) && !saving && !camera.isCapturing }

    var body: some View {
        GeometryReader { geometry in
            let previewWidth = min(geometry.size.width - 32, max(220, (geometry.size.height - 315) * 0.75))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    header
                    viewfinder
                        .frame(width: previewWidth, height: previewWidth * 4 / 3)
                        .frame(maxWidth: .infinity)
                    guidance
                    controls
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 18)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
        .background(Palette.ink)
        .onAppear { isVisible = true; if !demo { camera.start() } }
        .onDisappear { isVisible = false; camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && isVisible && !demo { camera.start() }
            else { camera.stop() }
        }
        .onChange(of: mode) { _, newMode in camera.setMode(newMode); restartDemo() }
        .onChange(of: guide) { _, enabled in camera.setGuidance(enabled) }
        .onChange(of: reading.state) { old, new in
            if new == .ready && old != .ready && guide {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
        }
        .task(id: demoReset) {
            guard demo else { return }
            let start = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let progress = min(elapsed / 3.5, 1)
                let target = CompositionEngine.target(for: demoSubject, mode: mode)
                let subject = UnitPoint2D(x: demoSubject.x + (target.x - demoSubject.x) * progress,
                                          y: demoSubject.y + (target.y - demoSubject.y) * progress)
                demoReading = demoEngine.update(subject: subject, rollDegrees: (1 - progress) * 9,
                                                mode: mode, timestamp: elapsed)
                do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            }
        }
        .sheet(isPresented: $showHelp) { FieldGuideView().presentationDragIndicator(.visible) }
        .alert("Camera", isPresented: Binding(get: { camera.errorMessage != nil }, set: { if !$0 { camera.errorMessage = nil } })) {
            Button("OK") { camera.errorMessage = nil }
        } message: { Text(camera.errorMessage ?? "") }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 3) {
                Text("focal").font(.system(size: 28, weight: .heavy, design: .rounded))
                Circle().fill(Palette.mint).frame(width: 6, height: 6).offset(y: 8)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(demo ? .orange : Palette.mint).frame(width: 5, height: 5)
                Eyebrow(text: demo ? "Demo camera" : "A fresh perspective")
            }
            .foregroundStyle(.white.opacity(0.65))
            Button { showHelp = true } label: {
                Image(systemName: "questionmark.circle").frame(width: 44, height: 44)
            }
            .foregroundStyle(.white.opacity(0.65))
            .accessibilityLabel("How composition guidance works")
        }
        .padding(.horizontal, 6)
    }

    private var viewfinder: some View {
        ZStack {
            if demo {
                GeometryReader { geometry in
                    Image("DemoScene").resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            } else if camera.access == .available {
                CameraPreview(session: camera.session, onFocus: camera.focus)
            } else {
                permissionView
            }
            if demo || camera.access == .available {
                CompositionOverlay(reading: reading, showGrid: grid, guideEnabled: guide)
                VStack {
                    HStack {
                        Label(demo ? "SIMULATED GUIDANCE" : guide ? "GUIDE ON" : "FREE SHOOT", systemImage: "viewfinder")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1.5)
                            .padding(10).background(.black.opacity(0.3), in: Capsule())
                        Spacer()
                        if demo {
                            Button {
                                demo = false
                                demoReset = UUID()
                                camera.start()
                            } label: { Image(systemName: "xmark").frame(width: 36, height: 36).background(.black.opacity(0.4), in: Circle()) }
                            .accessibilityLabel("Exit demo and use camera")
                        }
                    }
                    Spacer()
                    HStack {
                        Eyebrow(text: "01 / Wide")
                        Spacer()
                        Text("1×").font(.system(.caption, design: .rounded, weight: .medium))
                            .padding(11).background(.black.opacity(0.3), in: Circle())
                        Spacer()
                        Eyebrow(text: "3:4 / Photo")
                    }
                    .shadow(radius: 4)
                }
                .foregroundStyle(.white)
                .padding(16)
            }
            if saved {
                Label("Saved to your shots", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium)).padding(16)
                    .foregroundStyle(Palette.ink).background(Palette.mint, in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var permissionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "viewfinder").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(Palette.mint)
            Text(camera.access == .checking ? "A new way to see." : "Your eye. A little help.")
                .font(.system(.title2, design: .serif))
            Text(camera.access == .denied
                 ? "Allow camera access in Settings to find your next frame."
                 : camera.access == .unavailable
                 ? "A camera isn’t available here. Explore the guided demo, or run Focal on an iPhone."
                 : "Camera access lets Focal guide your composition, right on your iPhone.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if camera.access == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Palette.ink)
            }
            Button("Explore the demo") {
                camera.stop()
                demo = true
                restartDemo()
            }
            .font(.subheadline.weight(.semibold))
            .padding(8)
        }
        .padding(24)
    }

    private var guidance: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: guide && reading.state == .ready ? "checkmark.circle.fill" : "sparkle")
                    .foregroundStyle(Palette.mint)
                Text(guide ? reading.title : "Trust your eye")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(guide && reading.state == .ready ? Palette.mint : .white)
            }
            Text(guide ? reading.detail : "No directions. Just you and the moment.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(minHeight: 50)
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(CompositionMode.allCases) { item in
                    Button { mode = item } label: {
                        Text(item.rawValue).font(.caption.weight(.semibold))
                            .padding(.horizontal, 19).padding(.vertical, 9)
                            .foregroundStyle(mode == item ? Palette.ink : .white.opacity(0.55))
                            .background(mode == item ? Palette.paper : .clear, in: Capsule())
                    }
                    .accessibilityAddTraits(mode == item ? .isSelected : [])
                }
            }
            .padding(4).background(Palette.panel, in: Capsule())
            .disabled(!guide)
            HStack {
                RoundToolButton(symbol: "grid", label: "Composition grid", selected: grid) { grid.toggle() }
                Spacer()
                Button(action: shoot) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.85), lineWidth: 2).frame(width: 78, height: 78)
                        Circle().fill(reading.state == .ready && guide ? Palette.mint : Palette.paper).frame(width: 64, height: 64)
                        if saving || camera.isCapturing { ProgressView().tint(Palette.ink) }
                    }
                }
                .disabled(!canShoot)
                .opacity(canShoot || saving ? 1 : 0.4)
                .accessibilityLabel(demo ? "Save demo photo" : "Take photo")
                Spacer()
                RoundToolButton(symbol: "viewfinder", label: "Live composition guidance", selected: guide) { guide.toggle() }
            }
            .padding(.horizontal, 25)
            Eyebrow(text: demo ? "Sample scene · Tap shutter to try saving" : "Find your frame. Keep the moment.")
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private func restartDemo() {
        demoEngine.reset()
        demoReset = UUID()
    }

    private func shoot() {
        guard canShoot else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        saving = true
        if demo {
            guard let image = UIImage(named: "DemoScene"), let data = image.jpegData(compressionQuality: 0.95) else {
                saving = false
                camera.errorMessage = "The demo image could not be loaded."
                return
            }
            save(data, demo: true)
        } else {
            camera.capture { result in
                switch result {
                case .success(let data): save(data, demo: false)
                case .failure(let error): saving = false; camera.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func save(_ data: Data, demo: Bool) {
        let capturedMode = guide ? mode.rawValue : "Free shoot"
        Task {
            do {
                _ = try await library.add(data: data, mode: capturedMode, isDemo: demo)
                withAnimation { saved = true }
                try? await Task.sleep(for: .seconds(1.3))
                withAnimation { saved = false }
            } catch { camera.errorMessage = error.localizedDescription }
            saving = false
        }
    }
}
