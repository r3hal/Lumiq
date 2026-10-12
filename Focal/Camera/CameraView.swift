import SwiftUI

struct CameraView: View {
    @StateObject private var camera = CameraController()
    @EnvironmentObject private var library: PhotoLibrary
    @EnvironmentObject private var settings: CameraSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var demo = false
    @State private var showAspect = false
    @State private var showExposure = false
    @State private var showReference = false
    @State private var showExplore = false
    @State private var reference: UIImage?
    @State private var referenceOpacity = 0.35
    @State private var smartGate = SmartShutterGate()
    @State private var seriesProgress = ""
    @State private var showSettings = false
    @State private var showLibrary = false
    @State private var mode: CompositionMode = .thirds
    @State private var corner: Int?
    @State private var saving = false
    @State private var saved = false
    private var reading: CompositionReading { camera.reading }
    private var canShoot: Bool { (demo || camera.isRunning) && !saving && !camera.isCapturing && !camera.isSwitchingCamera && camera.framingPhase != .zooming }
    private var subjectName: String { ["Auto subject", "Your subject"].contains(camera.subjectLabel) ? "Subject" : camera.subjectLabel }
    private var closestStop: Double { camera.zoomStops.min(by: { abs($0 - camera.zoom) < abs($1 - camera.zoom) }) ?? 1 }

    var body: some View {
        GeometryReader { geometry in
            let availableHeight = max(160, geometry.size.height - 208)
            let width = min(geometry.size.width, availableHeight * settings.aspect.ratio)
            VStack(spacing: 0) {
                toolbar.frame(height: 44)
                ZStack { viewfinder.frame(width: width, height: width / settings.aspect.ratio) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer.frame(height: 164)
            }
        }
        .background(.black).foregroundStyle(.white)
        .onAppear {
            visible = true
            camera.setPreviewPixelWidth(Double(UIScreen.main.bounds.width * UIScreen.main.scale))
            camera.setCoach(settings.coach)
            camera.setMode(mode)
            camera.setAutoFraming(settings.autoFrame)
            camera.setGuidance(settings.guide)
            camera.setPreviewAspect(settings.aspect.ratio)
            if !demo { camera.start() }
        }
        .onDisappear { visible = false; camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && visible && !demo && !showSettings && !showLibrary && !showReference && !showExplore { camera.start() }
            else { camera.stop() }
        }
        .onChange(of: settings.coach) { _, value in camera.setCoach(value) }
        .onChange(of: settings.smartShutter) { _, _ in smartGate.reset() }
        .onChange(of: mode) { _, value in smartGate.reset(); camera.setMode(value) }
        .onChange(of: settings.guide) { _, value in smartGate.reset(); camera.setGuidance(value) }
        .onChange(of: settings.autoFrame) { _, value in smartGate.reset(); camera.setAutoFraming(value) }
        .onChange(of: settings.aspect) { _, value in smartGate.reset(); camera.setPreviewAspect(value.ratio) }
        .onChange(of: corner) { _, value in smartGate.reset(); camera.setTarget(value.map { CompositionEngine.thirdsTargets[$0] }) }
        .onChange(of: reading.state) { old, new in
            if old != .ready && new == .ready && settings.guide { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
        }
        .fullScreenCover(isPresented: $showSettings, onDismiss: resume) { SettingsView(camera: camera) }
        .sheet(isPresented: $showLibrary, onDismiss: resume) { LibraryView() }
        .sheet(isPresented: $showReference, onDismiss: resume) { ReferenceOverlayView(image: $reference,opacity: $referenceOpacity) }
        .sheet(isPresented: $showExplore, onDismiss: resume) { ExploreView() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(settings.smartShutter ? 250 : 1000))
                guard !Task.isCancelled else { return }
                let active = visible && scenePhase == .active && !demo && !showSettings && !showLibrary && !showReference && !showExplore
                if smartGate.shouldCapture(enabled: settings.smartShutter && settings.guide,ready: reading.state == .ready && !camera.framingPhase.isPreparing,
                                           active: active,busy: !canShoot,zooming: camera.framingPhase == .zooming) { shoot() }
            }
        }
        .alert("Camera", isPresented: Binding(get: { camera.errorMessage != nil }, set: { if !$0 { camera.errorMessage = nil } })) {
            Button("OK") { camera.errorMessage = nil }
        } message: { Text(camera.errorMessage ?? "") }
    }

    private var toolbar: some View {
        HStack(spacing: 20) {
            Button { showAspect.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: settings.aspect == .square ? "square" : settings.aspect.ratio > 1 ? "rectangle" : "rectangle.portrait").font(.system(size: 17))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(settings.aspect.rawValue).font(.system(size: 13, weight: .semibold))
                        if settings.raw && camera.supportsRAW {
                            Text("RAW").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(Palette.yellow)
                        }
                    }
                    Image(systemName: showAspect ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(showAspect ? Palette.yellow : Color.secondary)
                }.frame(minHeight: 44)
            }.accessibilityLabel("Aspect ratio and RAW options")
            Spacer()
            Button { settings.flash = CameraFlash.allCases[(settings.flash.rawValue + 1) % CameraFlash.allCases.count] } label: {
                Image(systemName: settings.flash.symbol).font(.system(size: 19)).frame(width: 30, height: 44)
                    .foregroundStyle(settings.flash == .off ? Color.white : Palette.yellow)
            }.disabled(!camera.supportsFlash || demo).accessibilityLabel("Flash \(settings.flash.label)")
            Menu {
                Toggle("Composition guide", isOn: $settings.guide)
                Button("Switch camera", systemImage: "camera.rotate") { camera.switchCamera() }.disabled(demo)
                Button("Exposure", systemImage: "plusminus.circle") { showExposure.toggle() }.disabled(demo)
                Toggle("Smart shutter", isOn: $settings.smartShutter)
                Toggle("Measured coach",isOn: $settings.coach)
                Button("Reference overlay",systemImage: "photo.on.rectangle") { camera.stop(); showReference = true }
                Button("Explore & practice",systemImage: "sparkles") { camera.stop(); showExplore = true }
                Picker("Composition", selection: $mode) {
                    Text("Thirds").tag(CompositionMode.thirds)
                    Text("Center").tag(CompositionMode.centered)
                }
                Button("Change thirds corner") {
                    corner = ((CompositionEngine.thirdsTargets.firstIndex(of: reading.target) ?? 0) + 1) % 4
                }.disabled(mode != .thirds)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "camera.aperture").font(.system(size: 19))
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }.frame(height: 44)
            }.accessibilityLabel("Guide and composition options")
            Button { showAspect = false; camera.stop(); showSettings = true } label: {
                Image(systemName: "ellipsis").font(.system(size: 21, weight: .bold)).frame(width: 30, height: 44)
            }.accessibilityLabel("Settings")
        }.padding(.horizontal, 20).disabled(saving || camera.isCapturing || camera.isSwitchingCamera || camera.framingPhase == .zooming)
    }

    private var viewfinder: some View {
        ZStack(alignment: .topLeading) {
            if demo {
                GeometryReader { geometry in
                    Image("DemoScene").resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                Text("DEMO").font(.caption.weight(.bold)).padding(12).foregroundStyle(Palette.yellow)
            } else if camera.access == .available {
                CameraPreview(session: camera.session, onFocus: { camera.focus(at: $0) },
                              onSelect: { smartGate.reset(); camera.selectSubject(at: $0) }, onZoom: { camera.setZoom($0) }, zoom: camera.zoom, mirrored: camera.isFrontCamera)
                    .disabled(saving || camera.isCapturing || camera.isSwitchingCamera)
            } else { permissionView.frame(maxWidth: .infinity, maxHeight: .infinity) }
            if camera.isSwitchingCamera {
                ProgressView("Switching camera…").tint(Palette.yellow).frame(maxWidth: .infinity,maxHeight: .infinity).background(.black.opacity(0.35))
            }
            if let reference, !demo {
                GeometryReader { geo in
                    Image(uiImage: reference).resizable().scaledToFill().frame(width: geo.size.width,height: geo.size.height).clipped().opacity(referenceOpacity)
                }.allowsHitTesting(false)
            }
            if demo || camera.access == .available {
                CompositionOverlay(reading: reading, showGrid: settings.grid, guideEnabled: settings.guide,
                                   showLevel: settings.level && camera.levelReliable, subjectLabel: subjectName, framingPhase: camera.framingPhase)
            }
            if settings.coach && !showExposure && !showAspect {
                VStack(alignment: .leading,spacing: 3) {
                    if let scene = camera.sceneLabel { Text("Frame label: \(scene)") }
                    if let measured = camera.liveMeasurements { Text(String(format: "Technical measure %.0f/100",measured.technicalScore)) }
                    if let alignment = reading.alignmentPercent(previewAspect: settings.aspect.ratio) { Text(String(format: "Guide alignment %.0f%%",alignment)) }
                }.font(.caption2).padding(7).background(.black.opacity(0.55),in: RoundedRectangle(cornerRadius: 7)).padding(12).allowsHitTesting(false)
            }
            if showExposure {
                VStack(spacing: 8) {
                    HStack {
                        Text(String(format: "Exposure %+.1f EV", camera.exposureBias)).font(.caption)
                        Spacer()
                        Button("Reset") { camera.setExposure(0) }
                        Button { showExposure = false } label: { Image(systemName: "xmark") }
                    }
                    Slider(value: Binding(get: { Double(camera.exposureBias) }, set: { camera.setExposure(Float($0)) }),
                           in: Double(camera.exposureRange.lowerBound)...Double(camera.exposureRange.upperBound))
                        .tint(Palette.yellow)
                }.padding(14).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 14)).padding(12)
                    .disabled(saving || camera.isCapturing || camera.isSwitchingCamera || camera.framingPhase == .zooming)
            }
            if showAspect {
                Color.clear.contentShape(Rectangle()).onTapGesture { showAspect = false }
                aspectMenu.padding(.leading, 12).padding(.top, 8)
            }
        }.clipped()
    }

    private var aspectMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Aspect ratio").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 5)
            ForEach(PhotoAspect.allCases) { aspect in
                Button { settings.aspect = aspect; showAspect = false } label: {
                    HStack(spacing: 10) {
                        Image(systemName: aspect == .square ? "square" : aspect.ratio > 1 ? "rectangle" : "rectangle.portrait").font(.system(size: 14))
                        Text(aspect.rawValue).font(.system(size: 16))
                        Spacer()
                        if settings.aspect == aspect { Image(systemName: "checkmark").foregroundStyle(Palette.yellow).font(.system(size: 12)) }
                    }
                    .padding(.horizontal, 12).frame(height: 34)
                    .foregroundStyle(settings.aspect == aspect ? Color.white : Color.secondary)
                    .background(settings.aspect == aspect ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(.horizontal, 6)
            Divider().overlay(Color.white.opacity(0.1)).padding(.horizontal, 12).padding(.vertical, 9)
            Toggle(isOn: $settings.raw) {
                HStack(spacing: 9) {
                    Image(systemName: "camera.aperture").foregroundStyle(Palette.yellow).font(.system(size: 13))
                    Text(camera.supportsProRAW ? "ProRAW" : "RAW").font(.system(size: 16, weight: .medium))
                }
            }.tint(Palette.yellow).controlSize(.mini).disabled(!camera.supportsRAW || demo)
                .padding(.horizontal, 14).padding(.bottom, 13)
            if !camera.supportsRAW {
                Text("Unavailable on this camera").font(.system(size: 9)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
        }.frame(width: 150).background(Color(white: 0.08).opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Text(instruction).font(.system(size: 12, weight: .medium)).foregroundStyle(camera.framingPhase.isPreparing || (camera.framingPhase == .off && reading.state == .adjusting) ? Palette.yellow : Palette.mint)
                .lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity).frame(height: 29).padding(.horizontal, 12)
            HStack(spacing: 7) {
                ForEach(demo ? [1.0] : camera.zoomStops, id: \.self) { stop in
                    let selected = closestStop == stop
                    Button { camera.setZoom(stop) } label: {
                        Text(zoomLabel(selected ? camera.zoom : stop))
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Palette.yellow : Color.secondary)
                            .frame(width: 36, height: 36)
                            .background(selected ? Palette.yellow.opacity(0.14) : Color(white: 0.07), in: Circle())
                    }.disabled(demo || saving || camera.isCapturing || camera.isSwitchingCamera).accessibilityLabel("Zoom \(zoomLabel(stop))")
                }
            }.frame(height: 43)
            HStack {
                Button { camera.stop(); showLibrary = true } label: { libraryThumbnail }
                    .accessibilityLabel("Open photo library").disabled(saving || camera.isCapturing || camera.isSwitchingCamera)
                Spacer()
                Button(action: shoot) {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 2).frame(width: 62, height: 62)
                        Circle().fill(.white).frame(width: 52, height: 52)
                        if saving || camera.isCapturing { ProgressView().tint(.black) }
                    }.frame(width: 70, height: 70)
                }.disabled(!canShoot).opacity(canShoot || saving ? 1 : 0.4).accessibilityLabel("Take photo")
                Spacer()
                Button {
                    if demo { demo = false; camera.start() }
                    if camera.framingPhase.isPreparing { camera.cancelAutoFraming() }
                    else { settings.guide = true; corner = nil; smartGate.reset(); camera.findSubject() }
                } label: {
                    Image(systemName: camera.framingPhase.isPreparing ? "xmark" : "arrow.clockwise").font(.system(size: 20)).foregroundStyle(Palette.yellow)
                        .frame(width: 48, height: 48).background(Palette.yellow.opacity(0.13), in: Circle())
                }.accessibilityLabel(camera.framingPhase.isPreparing ? "Cancel automatic framing" : "Scan scene and select a new subject").disabled(saving || camera.isCapturing || camera.isSwitchingCamera)
            }.padding(.horizontal, 54).frame(height: 80)
            Spacer(minLength: 0)
        }.background(.black)
    }

    private var libraryThumbnail: some View {
        Group {
            if let photo = library.photos.first { PhotoImage(url: library.url(for: photo), maxPixels: 180, fill: true) }
            else { Image(systemName: "photo").font(.system(size: 19)).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.panel) }
        }.frame(width: 40, height: 40).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.3), lineWidth: 1))
    }

    private var instruction: String {
        if !seriesProgress.isEmpty { return seriesProgress }
        if saved { return "Saved to your library." }
        if demo { return "Demo scene. Tap scan to return to the camera." }
        if !settings.guide {
            if settings.coach, let advice = camera.coachAdvice.first { return advice }
            return "Tap to focus. Pinch to zoom."
        }
        switch camera.framingPhase {
        case .searching: return "Finding your subject… Tap it to select."
        case .aligning:
            if abs(reading.rollDegrees) > 4 { return "Level your phone." }
            if let point = reading.subject {
                let dx = point.x - 0.5, dy = (point.y - 0.5) / settings.aspect.ratio
                let direction = abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up")
                return "Move your phone \(direction)."
            }
            return "Keep your subject in view."
        case .settling: return "Centered — framing up…"
        case .zooming: return "Framing your shot…"
        case .framed:
            if reading.subject == nil { return "Subject lost. Tap scan or select it again." }
            if abs(reading.rollDegrees) > 4 { return "Level your phone." }
            if settings.coach, let advice = camera.coachAdvice.first { return advice }
            return SubjectAdvice.text(for: subjectName)
        case .off: break
        }
        switch reading.state {
        case .searching: return "Point at a subject. Tap scan or select it yourself."
        case .adjusting: return reading.title + "."
        case .settling: return "Hold steady. Keep the subject in the guide."
        case .ready: return SubjectAdvice.text(for: subjectName)
        }
    }

    private var permissionView: some View {
        VStack(spacing: 16) {
            if camera.access == .checking { ProgressView("Starting camera…").tint(Palette.yellow) }
            else { Image(systemName: "camera").font(.system(size: 38, weight: .light))
            Text(camera.access == .denied ? "Allow camera access in Settings." : "Camera unavailable.")
                .font(.subheadline).foregroundStyle(.secondary)
            if camera.access == .denied {
                Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
            else { Button("Retry camera") { camera.start() } }
            Button("Open demo") { camera.stop(); demo = true }
            }
        }.padding(24).multilineTextAlignment(.center)
    }

    private func resume() { if visible && scenePhase == .active && !demo { camera.start() } }
    private func zoomLabel(_ value: Double) -> String {
        abs(value.rounded() - value) < 0.04 ? String(format: "%.0f×", value) : String(format: "%.1f×", value)
    }

    private func shoot() {
        guard canShoot else { return }
        smartGate.consume()
        showAspect = false; showExposure = false; saving = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let count = demo ? 1 : settings.burstCount
        let burst = count > 1 ? UUID() : nil
        let aspect = settings.aspect, caption = settings.caption
        let keepRAW = settings.keepRAW, autoSave = settings.autoSaveToPhotos
        let scan = settings.saveScan && !demo ? camera.scanData : nil
        let label = subjectName
        let capturedMode = settings.guide ? mode.rawValue : "Free shoot"
        let challenge = settings.challenge.isEmpty ? nil : settings.challenge
        let options = CaptureOptions(raw: settings.raw && camera.supportsRAW,flash: settings.flash,shutterSound: settings.shutterSound)
        Task {
            var added = [SavedPhoto]()
            do {
                for index in 0..<count {
                    guard scenePhase == .active && visible else { break }
                    seriesProgress = count > 1 ? "Capturing \(index+1) of \(count)…" : "Saving…"
                    let capture: CameraCapture
                    if demo {
                        guard let bytes = UIImage(named: "DemoScene")?.jpegData(compressionQuality: 0.95) else { throw CameraController.CameraError.missingPhoto }
                        capture = CameraCapture(processed: bytes,raw: nil)
                    } else {
                        capture = try await withCheckedThrowingContinuation { continuation in
                            camera.capture(options: options) { continuation.resume(with: $0) }
                        }
                    }
                    let rendered = try await Task.detached(priority: .userInitiated) {
                        let processed = try PhotoRenderer.crop(capture.processed,to: aspect)
                        return (processed, index == 0 ? scan.flatMap { PhotoRenderer.captionedScan($0,style: caption) } : nil)
                    }.value
                    let photo = try await library.add(data: rendered.0,mode: capturedMode,isDemo: demo,
                        rawData: keepRAW ? capture.raw : nil,originalData: rendered.0 == capture.processed ? nil : capture.processed,
                        scanData: rendered.1,aspect: aspect.rawValue,subject: label,challenge: challenge,burstID: burst)
                    added.append(photo)
                    if index+1 < count { try await Task.sleep(for: .milliseconds(180)) }
                }
                if autoSave {
                    for photo in added {
                        do { try await library.saveToPhotos(photo) }
                        catch { camera.errorMessage = "Saved in Focal. Photos export: \(error.localizedDescription)"; break }
                    }
                }
                saved = !added.isEmpty
            } catch {
                camera.errorMessage = (added.isEmpty ? "" : "Earlier shots are saved. ") + error.localizedDescription
            }
            saving = false; seriesProgress = ""
            try? await Task.sleep(for: .seconds(1.2))
            saved = false
        }
    }
}
