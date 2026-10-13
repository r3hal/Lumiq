import SwiftUI

struct CameraView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var sony = SonyRemoteCamera()
    @State private var source: CameraSource = .iPhone
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
    @State private var showExposureAdjustment = false
    @State private var captureTask: Task<Void,Never>?
    @State private var captureGeneration = UUID()
    @State private var showSettings = false
    @State private var showLibrary = false
    @State private var mode: CompositionMode = .centered
    @State private var corner: Int?
    @State private var saving = false
    @State private var saved = false
    private var reading: CompositionReading { camera.reading }
    private var canShoot: Bool { (source == .sony ? sony.canCapture : (demo || camera.isRunning)) && !saving && !camera.isCapturing && !camera.isSwitchingCamera && camera.framingPhase != .zooming }
    private var subjectName: String { ["Auto subject", "Your subject"].contains(camera.subjectLabel) ? "Subject" : camera.subjectLabel }
    private var closestStop: Double { camera.zoomStops.min(by: { abs($0 - camera.zoom) < abs($1 - camera.zoom) }) ?? 1 }

    // Opaque view boundaries keep SwiftUI's constraint solver from checking the
    // layout, every observer and every presentation as one enormous expression.
    var body: some View {
        presentedCamera
            .task { await monitorSmartShutter() }
            .alert("Camera", isPresented: cameraErrorPresented) {
                Button("OK") { camera.errorMessage = nil }
            } message: {
                Text(camera.errorMessage ?? "")
            }
    }

    private var cameraLayout: some View {
        GeometryReader { geometry in
            let aspect: CGFloat = CGFloat(settings.aspect.ratio)
            let availableHeight: CGFloat = max(160, geometry.size.height - 208)
            let width: CGFloat = min(geometry.size.width, availableHeight * aspect)
            VStack(spacing: 0) {
                toolbar.frame(height: 44)
                ZStack { viewfinder.frame(width: width, height: width / aspect) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer.frame(height: 164)
            }
        }
        .background(Color.black)
        .foregroundStyle(Color.white)
    }

    private var lifecycleCamera: some View {
        cameraLayout
            .onAppear(perform: configureCamera)
            .onDisappear { visible = false; pauseActiveSource() }
            .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
            .onChange(of: source) { _, value in changeSource(to: value) }
    }

    private var preferenceCamera: some View {
        lifecycleCamera
            .onChange(of: settings.holdDuration) { _, value in camera.setHoldDuration(value) }
            .onChange(of: settings.coach) { _, value in camera.setCoach(value) }
            .onChange(of: settings.smartShutter) { _, _ in smartGate.reset() }
            .onChange(of: mode) { _, value in smartGate.reset(); camera.setMode(value) }
    }

    private var compositionCamera: some View {
        preferenceCamera
            .onChange(of: settings.guide) { _, value in smartGate.reset(); camera.setGuidance(value) }
            .onChange(of: settings.autoFrame) { _, value in smartGate.reset(); camera.setAutoFraming(value) }
            .onChange(of: settings.aspect) { _, value in smartGate.reset(); camera.setPreviewAspect(value.ratio) }
            .onChange(of: corner) { _, value in changeCorner(to: value) }
            .onChange(of: reading.state) { old, new in
                if old != .ready && new == .ready && settings.guide {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
            }
    }

    private var presentedCamera: some View {
        compositionCamera
            .fullScreenCover(isPresented: $showSettings, onDismiss: resume) {
                SettingsView(camera: camera, source: source, sonyResolution: sony.resolution, sonyModel: sony.model)
            }
            .sheet(isPresented: $showLibrary, onDismiss: resume) { LibraryView() }
            .sheet(isPresented: $showReference, onDismiss: resume) {
                ReferenceOverlayView(image: $reference, opacity: $referenceOpacity)
            }
            .sheet(isPresented: $showExplore, onDismiss: resume) { ExploreView() }
    }

    private var cameraErrorPresented: Binding<Bool> {
        Binding(get: { camera.errorMessage != nil }, set: { if !$0 { camera.errorMessage = nil } })
    }

    private func configureCamera() {
        visible = true
        camera.setPreviewPixelWidth(Double(UIScreen.main.bounds.width * UIScreen.main.scale))
        let analyzer = camera
        sony.onJPEG = { [weak analyzer] in analyzer?.analyzeExternalFrame($0) }
        camera.setAnalysisSource(source)
        camera.setHoldDuration(settings.holdDuration)
        camera.setCoach(settings.coach)
        camera.setMode(mode)
        camera.setAutoFraming(settings.autoFrame)
        camera.setGuidance(settings.guide)
        camera.setPreviewAspect(settings.aspect.ratio)
        resume()
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active && visible && !showSettings && !showLibrary && !showReference && !showExplore {
            resume()
        } else { pauseActiveSource() }
    }

    private func changeSource(to value: CameraSource) {
        captureGeneration = UUID(); captureTask?.cancel(); saving = false; seriesProgress = ""
        camera.stop(); sony.disconnect(); demo = false; showExposure = false
        smartGate.reset(); camera.setAnalysisSource(value)
        if value == .iPhone { camera.start() }
    }

    private func changeCorner(to value: Int?) {
        smartGate.reset()
        let target: UnitPoint2D? = value.map { CompositionEngine.thirdsTargets[$0] }
        camera.setTarget(target)
    }

    @MainActor private func monitorSmartShutter() async {
        while !Task.isCancelled {
            let interval: Duration = settings.smartShutter ? .milliseconds(250) : .milliseconds(1000)
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            let active: Bool = visible && scenePhase == .active && !demo && source == .iPhone
                && !showSettings && !showLibrary && !showReference && !showExplore
            let ready: Bool = reading.state == .ready && camera.guidance.kind == .ready && !camera.framingPhase.isPreparing
            let shouldCapture: Bool = smartGate.shouldCapture(
                enabled: settings.smartShutter && settings.guide, ready: ready,
                active: active, busy: !canShoot, zooming: camera.framingPhase == .zooming)
            if shouldCapture { shoot() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 20) {
            aspectButton
            Spacer()
            flashButton
            exposureButton
            cameraMenu
        }
        .padding(.horizontal, 20)
        .disabled(source == .iPhone && controlsBusy)
    }

    private var aspectButton: some View {
        Button { showAspect.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: aspectSymbol(settings.aspect)).font(.system(size: 17))
                VStack(alignment: .leading, spacing: 0) {
                    Text(settings.aspect.rawValue).font(.system(size: 13, weight: .semibold))
                    if settings.raw && camera.supportsRAW && source == .iPhone {
                        Text("RAW").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(Palette.yellow)
                    }
                }
                Image(systemName: showAspect ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(showAspect ? Palette.yellow : Color.secondary)
            }.frame(minHeight: 44)
        }.accessibilityLabel("Aspect ratio and RAW options")
    }

    private var flashButton: some View {
        Button { settings.flash = CameraFlash.allCases[(settings.flash.rawValue + 1) % CameraFlash.allCases.count] } label: {
            Image(systemName: settings.flash.symbol).font(.system(size: 19)).frame(width: 30, height: 44)
                .foregroundStyle(settings.flash == .off ? Color.white : Palette.yellow)
        }
        .disabled(!camera.supportsFlash || demo || source == .sony)
        .accessibilityLabel("Flash \(settings.flash.label)")
    }

    private var exposureButton: some View {
        Button { showAspect = false; showExposure.toggle(); showExposureAdjustment = false } label: {
            HStack(spacing: 5) {
                Image(systemName: "camera.aperture").font(.system(size: 19))
                Image(systemName: showExposure ? "chevron.up" : "chevron.down").font(.system(size: 8))
            }.frame(height: 44).foregroundStyle(showExposure ? Palette.yellow : Color.white)
        }.accessibilityLabel("Expand camera exposure settings")
    }

    private var cameraMenu: some View {
        Menu {
            cameraSourceMenu
            automationMenu
            toolsMenu
            compositionMenu
            if source == .sony {
                Button("Disconnect Sony", role: .destructive) { sony.disconnect(); camera.findSubject() }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 21, weight: .bold)).frame(width: 30, height: 44)
        }.accessibilityLabel("Camera Source and settings")
    }

    @ViewBuilder private var cameraSourceMenu: some View {
        Picker("Camera Source", selection: $source) {
            ForEach(CameraSource.allCases) { value in Text(value.rawValue).tag(value) }
        }
        Button("Settings", systemImage: "gearshape") { pauseActiveSource(); showSettings = true }
    }

    @ViewBuilder private var automationMenu: some View {
        Toggle("Composition guide", isOn: $settings.guide)
        Button("Switch camera", systemImage: "camera.rotate") { camera.switchCamera() }
            .disabled(demo || source == .sony)
        Toggle("Smart shutter", isOn: $settings.smartShutter).disabled(source == .sony)
        Toggle("Automatic zoom", isOn: $settings.autoFrame).disabled(source == .sony)
        Toggle("Measured coach", isOn: $settings.coach)
    }

    @ViewBuilder private var toolsMenu: some View {
        Button("Reference overlay", systemImage: "photo.on.rectangle") { pauseActiveSource(); showReference = true }
        Button("Explore & practice", systemImage: "sparkles") { pauseActiveSource(); showExplore = true }
    }

    @ViewBuilder private var compositionMenu: some View {
        Picker("Composition", selection: $mode) {
            Text("Thirds").tag(CompositionMode.thirds)
            Text("Center").tag(CompositionMode.centered)
        }.disabled(settings.autoFrame && source == .iPhone)
        Button("Change thirds corner") {
            corner = ((CompositionEngine.thirdsTargets.firstIndex(of: reading.target) ?? 0) + 1) % 4
        }.disabled(mode != .thirds || (settings.autoFrame && source == .iPhone))
    }

    private var controlsBusy: Bool { saving || camera.isCapturing || camera.isSwitchingCamera }

    private func aspectSymbol(_ aspect: PhotoAspect) -> String {
        if aspect == .square { return "square" }
        return aspect.ratio > 1 ? "rectangle" : "rectangle.portrait"
    }

    private var viewfinder: some View {
        ZStack(alignment: .topLeading) {
            previewContent
            switchingOverlay
            referenceOverlay
            subjectOverlay
            coachOverlay
            aspectOverlay
        }
        .clipped()
        .overlay(alignment: .bottom) {
            if showExposure {
                exposureStrip.padding(.horizontal, 10).padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showExposure)
    }

    @ViewBuilder private var previewContent: some View {
        if source == .sony { sonyPreview }
        else if demo { demoPreview }
        else if camera.access == .available { nativePreview }
        else { permissionView.frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private var nativePreview: some View {
        CameraPreview(
            session: camera.session, onFocus: { camera.focus(at: $0) },
            onSelect: { smartGate.reset(); camera.selectSubject(at: $0) },
            onZoom: { camera.setZoom($0) }, zoom: camera.zoom,
            onPinchBegin: { camera.beginManualZoom(completion: $0) }, mirrored: camera.isFrontCamera)
            .disabled(controlsBusy)
    }

    @ViewBuilder private var sonyPreview: some View {
        if let frame = sony.frame {
            GeometryReader { geometry in
                Image(uiImage: frame).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { (point: CGPoint) in
                        selectSonySubject(at: point, size: geometry.size, frame: frame)
                    }
            }
        } else {
            SonyConnectionView(camera: sony) { source = .iPhone }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func selectSonySubject(at point: CGPoint, size: CGSize, frame: UIImage) {
        guard size.width > 0, size.height > 0, frame.size.height > 0 else { return }
        let visible = UnitPoint2D(x: Double(point.x / size.width), y: Double(point.y / size.height))
        camera.selectSubject(at: visible)
        let imageAspect: Double = Double(frame.size.width / frame.size.height)
        let projection = PreviewProjection(imageAspect: imageAspect, previewAspect: settings.aspect.ratio)
        sony.focus(at: projection.imagePoint(visible))
    }

    @ViewBuilder private var demoPreview: some View {
        GeometryReader { geometry in
            Image("DemoScene").resizable().scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        Text("DEMO").font(.caption.weight(.bold)).padding(12).foregroundStyle(Palette.yellow)
    }

    @ViewBuilder private var switchingOverlay: some View {
        if camera.isSwitchingCamera {
            ProgressView("Switching camera…").tint(Palette.yellow)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.35))
        }
    }

    @ViewBuilder private var referenceOverlay: some View {
        if let reference, !demo {
            GeometryReader { geometry in
                Image(uiImage: reference).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped().opacity(referenceOpacity)
            }.allowsHitTesting(false)
        }
    }

    private var hasLivePreview: Bool {
        if source == .sony { return sony.frame != nil }
        return !demo && camera.access == .available
    }

    @ViewBuilder private var subjectOverlay: some View {
        if hasLivePreview {
            CompositionOverlay(
                reading: reading, showGrid: settings.grid, guideEnabled: settings.guide,
                showLevel: settings.level && camera.levelReliable && source == .iPhone,
                subjectLabel: subjectName, framingPhase: camera.framingPhase)
        }
    }

    @ViewBuilder private var coachOverlay: some View {
        if settings.coach && !showExposure && !showAspect && (source == .iPhone ? camera.isRunning : sony.frame != nil) {
            VStack(alignment: .leading, spacing: 3) {
                if let scene = camera.sceneLabel { Text("Frame label: \(scene)") }
                if let measured = camera.liveMeasurements {
                    Text(String(format: "Technical measure %.0f/100", measured.technicalScore))
                }
                if let alignment = reading.alignmentPercent(previewAspect: settings.aspect.ratio) {
                    Text(String(format: "Guide alignment %.0f%%", alignment))
                }
            }
            .font(.caption2).padding(7)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
            .padding(12).allowsHitTesting(false)
        }
    }

    @ViewBuilder private var aspectOverlay: some View {
        if showAspect {
            Color.clear.contentShape(Rectangle()).onTapGesture { showAspect = false }
            aspectMenu.padding(.leading, 12).padding(.top, 8)
        }
    }

    private var activeTelemetry: CameraTelemetry {
        if source == .sony { return sony.telemetry }
        return demo ? CameraTelemetry() : camera.telemetry
    }

    private var exposureStrip: some View {
        VStack(spacing: 8) {
            exposureReadings
            if showExposureAdjustment && source == .iPhone && !demo { exposureAdjustment }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 9))
    }

    private var exposureReadings: some View {
        let live: CameraTelemetry = activeTelemetry
        return HStack(spacing: 0) {
            Text(live.mode ?? "—").foregroundStyle(Palette.yellow).lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Exposure mode \(live.mode ?? "unavailable"), read only")
            Divider().frame(height: 14)
            Text(live.shutter ?? "—").frame(maxWidth: .infinity)
                .accessibilityLabel("Shutter speed \(live.shutter ?? "unavailable"), read only")
            Divider().frame(height: 14)
            Text(live.iso.map { "ISO \($0)" } ?? "ISO —").frame(maxWidth: .infinity)
                .accessibilityLabel("ISO \(live.iso ?? "unavailable"), read only")
            Divider().frame(height: 14)
            exposureCompensationButton
        }.font(.system(size: 12, weight: .medium)).frame(height: 28)
    }

    private var exposureCompensationButton: some View {
        let live: CameraTelemetry = activeTelemetry
        let label: String = live.ev == 0 ? "±0" : live.evLabel
        return Button { showExposureAdjustment.toggle() } label: {
            Text(label).foregroundStyle(showExposureAdjustment ? Palette.yellow : Color.white)
                .frame(maxWidth: .infinity)
        }
        .disabled(source == .sony || demo || saving || camera.isCapturing || camera.framingPhase == .zooming)
        .accessibilityLabel("Exposure compensation \(live.evLabel)")
        .accessibilityHint(source == .iPhone ? "Adjust compensation" : "Read only; adjust on camera")
    }

    private var exposureValue: Binding<Double> {
        Binding(get: { Double(camera.exposureBias) }, set: { camera.setExposure(Float($0)) })
    }

    private var exposureRange: ClosedRange<Double> {
        Double(camera.exposureRange.lowerBound)...Double(camera.exposureRange.upperBound)
    }

    private var exposureAdjustment: some View {
        VStack(spacing: 8) {
            Slider(value: exposureValue, in: exposureRange).tint(Palette.yellow)
                .disabled(saving || camera.isCapturing || camera.framingPhase == .zooming)
            HStack {
                Text(activeTelemetry.aperture.map { "\($0) · fixed lens aperture" } ?? "Fixed lens aperture")
                    .font(.caption2).foregroundStyle(Color.secondary)
                Spacer()
                Button("Reset EV") { camera.setExposure(0) }.font(.caption)
            }
        }
    }

    private var aspectMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Aspect ratio").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.secondary)
                .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 5)
            ForEach(PhotoAspect.allCases) { aspect in aspectOption(aspect) }.padding(.horizontal, 6)
            Divider().overlay(Color.white.opacity(0.1)).padding(.horizontal, 12).padding(.vertical, 9)
            rawToggle
            if !camera.supportsRAW || source == .sony {
                Text("Unavailable on this camera").font(.system(size: 9)).foregroundStyle(Color.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
        }.frame(width: 150).background(Color(white: 0.08).opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
    }

    private func aspectOption(_ aspect: PhotoAspect) -> some View {
        let selected: Bool = settings.aspect == aspect
        let foreground: Color = selected ? Color.white : Color.secondary
        let background: Color = selected ? Color.white.opacity(0.07) : Color.clear
        return Button { settings.aspect = aspect; showAspect = false } label: {
            HStack(spacing: 10) {
                Image(systemName: aspectSymbol(aspect)).font(.system(size: 14))
                Text(aspect.rawValue).font(.system(size: 16))
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Palette.yellow).font(.system(size: 12)) }
            }
            .padding(.horizontal, 12).frame(height: 34).foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var rawToggle: some View {
        Toggle(isOn: $settings.raw) {
            HStack(spacing: 9) {
                Image(systemName: "camera.aperture").foregroundStyle(Palette.yellow).font(.system(size: 13))
                Text(camera.supportsProRAW ? "ProRAW" : "RAW").font(.system(size: 16, weight: .medium))
            }
        }.tint(Palette.yellow).controlSize(.mini).disabled(!camera.supportsRAW || demo || source == .sony)
            .padding(.horizontal, 14).padding(.bottom, 13)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            guidanceText
            lensButtons
            captureButtons
            Spacer(minLength: 0)
        }.background(Color.black)
    }

    private var guidanceColor: Color {
        if camera.framingPhase.isPreparing || (camera.framingPhase == .off && reading.state == .adjusting) {
            return Palette.yellow
        }
        return Palette.mint
    }

    private var guidanceText: some View {
        Text(instruction).font(.system(size: 12, weight: .medium)).foregroundStyle(guidanceColor)
            .lineLimit(2).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).frame(height: 29).padding(.horizontal, 12)
    }

    private var lensStops: [Double] {
        if source == .sony { return [] }
        return demo ? [1.0] : camera.zoomStops
    }

    private var lensButtons: some View {
        HStack(spacing: 7) {
            if source == .sony { Text("Sony lens · zoom on camera").font(.caption).foregroundStyle(Color.secondary) }
            ForEach(lensStops, id: \.self) { stop in zoomButton(stop) }
        }.frame(height: 43)
    }

    private func zoomButton(_ stop: Double) -> some View {
        let selected: Bool = closestStop == stop
        let label: String = zoomLabel(selected ? camera.zoom : stop)
        let foreground: Color = selected ? Palette.yellow : Color.secondary
        let background: Color = selected ? Palette.yellow.opacity(0.14) : Color(white: 0.07)
        return Button { camera.setZoom(stop) } label: {
            Text(label).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(foreground).frame(width: 36, height: 36)
                .background(background, in: Circle())
        }.disabled(demo || controlsBusy).accessibilityLabel("Zoom \(zoomLabel(stop))")
    }

    private var captureButtons: some View {
        HStack {
            Button { pauseActiveSource(); showLibrary = true } label: { libraryThumbnail }
                .accessibilityLabel("Open photo library").disabled(controlsBusy)
            Spacer()
            shutterButton
            Spacer()
            scanButton
        }.padding(.horizontal, 54).frame(height: 80)
    }

    private var shutterButton: some View {
        Button(action: shoot) {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 2).frame(width: 62, height: 62)
                Circle().fill(Color.white).frame(width: 52, height: 52)
                if saving || camera.isCapturing { ProgressView().tint(Color.black) }
            }.frame(width: 70, height: 70)
        }.disabled(!canShoot).opacity(canShoot || saving ? 1 : 0.4).accessibilityLabel("Take photo")
    }

    private var scanButton: some View {
        Button {
            if demo { demo = false; camera.start() }
            settings.guide = true; smartGate.reset(); camera.findSubject()
        } label: {
            Image(systemName: "arrow.clockwise").font(.system(size: 20)).foregroundStyle(Palette.yellow)
                .frame(width: 48, height: 48).background(Palette.yellow.opacity(0.13), in: Circle())
        }.accessibilityLabel("Scan scene and select a new subject").disabled(controlsBusy)
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
        if source == .sony && sony.state != .streaming { return sony.state == .connecting ? "Connecting to Sony…" : "Connect a Sony camera for guidance" }
        if !settings.guide { return "Tap to select. Frame manually." }
        if camera.guidance.kind == .ready,settings.coach,let advice = camera.coachAdvice.first { return camera.guidance.text+" · "+advice }
        return camera.guidance.text
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

    private func pauseActiveSource() { camera.stop(); sony.pause() }
    private func resume() {
        guard visible,scenePhase == .active else { return }
        if source == .iPhone { if !demo { camera.start() } }
        else { sony.resume() }
    }
    private func zoomLabel(_ value: Double) -> String {
        abs(value.rounded() - value) < 0.04 ? String(format: "%.0f×", value) : String(format: "%.1f×", value)
    }

    private func shoot() {
        guard canShoot else { return }
        smartGate.consume()
        showAspect = false; showExposure = false; saving = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let capturedSource = source
        let capturedDemo = demo && source == .iPhone
        let operation = UUID(); captureGeneration = operation
        let count = capturedDemo || source == .sony ? 1 : settings.burstCount
        let burst = count > 1 ? UUID() : nil
        let aspect = settings.aspect, caption = settings.caption
        let keepRAW = settings.keepRAW, autoSave = settings.autoSaveToPhotos
        let scan = settings.saveScan && !demo ? camera.scanData : nil
        let label = subjectName
        let capturedMode = settings.guide ? mode.rawValue : "Free shoot"
        let challenge = settings.challenge.isEmpty ? nil : settings.challenge
        let options = CaptureOptions(raw: settings.raw && camera.supportsRAW && source == .iPhone,flash: settings.flash,shutterSound: settings.shutterSound)
        captureTask = Task {
            var added = [SavedPhoto]()
            do {
                for index in 0..<count {
                    guard scenePhase == .active && visible else { break }
                    seriesProgress = count > 1 ? "Capturing \(index+1) of \(count)…" : "Saving…"
                    let capture: CameraCapture
                    if capturedSource == .sony { capture = try await sony.capture() }
                    else if capturedDemo {
                        guard let bytes = UIImage(named: "DemoScene")?.jpegData(compressionQuality: 0.95) else { throw CameraController.CameraError.missingPhoto }
                        capture = CameraCapture(processed: bytes,raw: nil)
                    } else {
                        capture = try await withCheckedThrowingContinuation { continuation in
                            camera.capture(options: options) { continuation.resume(with: $0) }
                        }
                    }
                    try Task.checkCancellation()
                    let rendered = try await Task.detached(priority: .userInitiated) {
                        let processed = try PhotoRenderer.crop(capture.processed,to: aspect)
                        return (processed, index == 0 ? scan.flatMap { PhotoRenderer.captionedScan($0,style: caption) } : nil)
                    }.value
                    try Task.checkCancellation()
                    let photo = try await library.add(data: rendered.0,mode: capturedMode,isDemo: capturedDemo,
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
                if operation == captureGeneration { saved = !added.isEmpty }
            } catch {
                guard operation == captureGeneration,!Task.isCancelled else { return }
                camera.errorMessage = (added.isEmpty ? "" : "Earlier shots are saved. ") + error.localizedDescription
            }
            guard operation == captureGeneration else { return }
            saving = false; seriesProgress = ""
            try? await Task.sleep(for: .seconds(1.2))
            if operation == captureGeneration { saved = false }
        }
    }
}
