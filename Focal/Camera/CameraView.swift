import SwiftUI

struct CameraView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var sony = SonyRemoteCamera()
    @State private var source: CameraSource = .iPhone
    @State private var immersivePreviewAspect = 0.75
    @State private var sonyFullFrame = true
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
    @State private var seriesProgress = ""
    @State private var showExposureAdjustment = false
    @State private var captureTask: Task<Void,Never>?
    @State private var captureGeneration = UUID()
    @State private var reviewPhoto: SavedPhoto?
    @State private var reviewAutoSave = false
    @State private var showCameraPanel = false
    @State private var startSettings = false
    @State private var openSonyPanel = false
    @State private var pendingPanelAction: PanelAction?
    private enum PanelAction { case reference, explore }
    @State private var showLibrary = false
    @State private var mode: CompositionMode = .automatic
    @State private var corner: Int?
    @State private var saving = false
    @State private var saved = false
    private var reading: CompositionReading { camera.reading }
    private var canShoot: Bool { (source == .sony ? sony.canCapture : (demo || camera.isRunning)) && !saving && !camera.isCapturing && !camera.isSwitchingCamera && !camera.framingPhase.isAutoFraming && !showCameraPanel && reviewPhoto == nil }
    private var subjectName: String { SubjectIdentity.name(camera.subjectLabel) ?? "Selected subject" }
    private var viewfinderAspect: Double {
        if source == .sony && sonyFullFrame { return sony.imageAspect }
        return source == .iPhone && settings.aspect == .standard ? immersivePreviewAspect : settings.aspect.ratio
    }
    private var aspectTitle: String { source == .sony && sonyFullFrame ? "Camera" : settings.aspect.rawValue }
    private var closestStop: Double { camera.zoomStops.min(by: { abs($0 - camera.zoom) < abs($1 - camera.zoom) }) ?? 1 }
    private var rawEnabled: Bool { source == .iPhone && !demo && settings.raw && camera.supportsRAW }
    private var rawBinding: Binding<Bool> {
        Binding(get: { rawEnabled }, set: { settings.raw = $0 })
    }

    // Opaque view boundaries keep SwiftUI's constraint solver from checking the
    // layout, every observer and every presentation as one enormous expression.
    var body: some View {
        presentedCamera
            .alert("Camera", isPresented: cameraErrorPresented) {
                Button("OK") { camera.errorMessage = nil }
            } message: {
                Text(camera.errorMessage ?? "")
            }
    }

    private var cameraLayout: some View {
        GeometryReader { geometry in
            let footerHeight: CGFloat = source == .sony ? 128 : 120
            let availableHeight: CGFloat = max(160, geometry.size.height - 94 - footerHeight)
            let targetAspect = CameraViewportLayout.aspect(source: source, capture: settings.aspect,
                sonyFullFrame: sonyFullFrame, sonyAspect: sony.imageAspect, width: Double(geometry.size.width), height: Double(availableHeight))
            let aspect: CGFloat = CGFloat(targetAspect)
            let width: CGFloat = min(geometry.size.width, availableHeight * aspect)
            VStack(spacing: 0) {
                toolbar.frame(height: 50)
                professionalStatus.frame(height:44)
                ZStack { viewfinder.frame(width: width, height: width / aspect) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).zIndex(1)
                footer.frame(height: footerHeight)
            }
            .onChange(of: targetAspect, initial: true) { _, value in immersivePreviewAspect = value }
        }
        .background(Palette.ink.ignoresSafeArea())
        .foregroundStyle(Palette.text)
    }

    private var lifecycleCamera: some View {
        cameraLayout
            .onAppear(perform: configureCamera)
            .onDisappear { visible = false; pauseActiveSource() }
            .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
            .onChange(of: source) { _, value in changeSource(to: value) }
            .onChange(of: showCameraPanel) { _, value in camera.setInterfacePaused(value) }
            .onChange(of: sony.hasFrame) { _, value in
                if source == .sony && !value { camera.setAnalysisSource(.sony) }
            }
            .onChange(of: sony.isCapturing) { _, value in
                if source == .sony && value { camera.setAnalysisSource(.sony) }
            }
    }

    private var preferenceCamera: some View {
        lifecycleCamera
            .onChange(of: settings.subjectThreshold) { _, value in camera.setSubjectThreshold(value) }
            .onChange(of: settings.holdDuration) { _, value in camera.setHoldDuration(value) }
            .onChange(of: settings.petDetection) { _, _ in configureSubjectFeatures() }
            .onChange(of: settings.subjectTracking) { _, _ in configureSubjectFeatures(); camera.setAutoFraming(settings.autoFrame && settings.subjectTracking) }
            .onChange(of: settings.smartSelection) { _, _ in configureSubjectFeatures() }
            .onChange(of: settings.coach) { _, value in camera.setCoach(value) }
            .onChange(of: mode) { _, value in camera.setMode(value) }
            .onChange(of: settings.compositionPlanning) { _, value in camera.setCompositionPlanning(value) }
            .onChange(of: settings.petFraming) { _, value in camera.setPetFraming(value) }
            .onChange(of: settings.intent) { _, value in camera.setIntent(value) }
    }

    private var compositionCamera: some View {
        preferenceCamera
            .onChange(of: settings.guide) { _, value in changeGuidance(to: value) }
            .onChange(of: settings.autoFrame) { _, value in camera.setAutoFraming(value && settings.subjectTracking) }
            .onChange(of: viewfinderAspect) { _, value in camera.setPreviewAspect(value) }
            .onChange(of: corner) { _, value in changeCorner(to: value) }
            .onChange(of: reading.state) { old, new in
                if old != .ready && new == .ready && settings.guide {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
            }
    }

    private var precisionOptions: PrecisionOptions {
        .init(histogram:settings.histogram,highlights:settings.highlightWarnings,peaking:settings.focusPeaking,autoTune:settings.autoTune)
    }
    private var instrumentedCamera: some View {
        compositionCamera
            .onChange(of:precisionOptions) { _,value in camera.setPrecisionOptions(value) }
    }

    private var presentedCamera: some View {
        instrumentedCamera
            .sheet(isPresented: $showCameraPanel, onDismiss: finishCameraPanel) {
                CameraOptionsSheet(camera: camera, sony: sony, source: $source, mode: $mode, corner: $corner,
                    sonyFullFrame: $sonyFullFrame, startsWithSony: openSonyPanel,
                    startsWithSettings:startSettings,
                    openReference: { pendingPanelAction = .reference }, openExplore: { pendingPanelAction = .explore })
            }
            .fullScreenCover(item: $reviewPhoto, onDismiss: resume) { photo in
                PhotoEditorView(photo: photo, captureReview: true, autoSaveOnReview: reviewAutoSave)
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
        sony.onImage = { [weak analyzer] in analyzer?.analyzeExternalFrame($0) }
        camera.setAnalysisSource(source)
        camera.setSubjectThreshold(settings.subjectThreshold)
        camera.setHoldDuration(settings.holdDuration)
        camera.setCoach(settings.coach)
        camera.setMode(mode,userInitiated:false)
        camera.setCompositionPlanning(settings.compositionPlanning)
        camera.setPetFraming(settings.petFraming)
        camera.setIntent(settings.intent,userInitiated:false)
        camera.setPrecisionOptions(precisionOptions)
        configureSubjectFeatures()
        camera.setAutoFraming(settings.autoFrame && settings.subjectTracking)
        camera.setGuidance(settings.guide)
        camera.setPreviewAspect(viewfinderAspect)
        resume()
    }

    private func configureSubjectFeatures() {
        camera.setSubjectFeatures(pets: settings.petDetection, tracking: settings.subjectTracking, smartSelection: settings.smartSelection)
    }
    private func finishCameraPanel() {
        openSonyPanel = false
        startSettings = false
        camera.setInterfacePaused(false)
        let next = pendingPanelAction; pendingPanelAction = nil
        switch next {
        case .reference: pauseActiveSource(); showReference = true
        case .explore: pauseActiveSource(); showExplore = true
        case nil: resume()
        }
    }

    private func changeGuidance(to enabled: Bool) {
        camera.setGuidance(enabled)
        if enabled && demo { demo = false; camera.start() }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active && showCameraPanel {
            if source == .sony { sony.resume() }
            return
        }
        if phase == .active && visible && !showCameraPanel && !showLibrary && !showReference && !showExplore && reviewPhoto == nil {
            resume()
        } else { pauseActiveSource() }
    }

    private func changeSource(to value: CameraSource) {
        captureGeneration = UUID(); captureTask?.cancel(); saving = false; seriesProgress = ""
        camera.stop(); sony.disconnect(); demo = false; showExposure = false
        camera.setAnalysisSource(value)
        if value == .iPhone { if !showCameraPanel { camera.start() } }
        else { sonyFullFrame = true }
    }

    private func changeCorner(to value: Int?) {
        let target: UnitPoint2D? = value.map { CompositionEngine.thirdsTargets[$0] }
        camera.setTarget(target)
    }

    private var toolbar: some View {
        HStack(spacing: 20) {
            VStack(alignment:.leading,spacing:2) {
                Text("FOCAL").font(.system(size:18,weight:.semibold)).tracking(4)
                if source == .sony { Text(sony.hasFrame ? sony.model : "SONY LINK").font(.system(size:9,design:.monospaced)).foregroundStyle(Palette.muted).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if source == .iPhone && camera.supportsFlash { flashButton }
            Button { startSettings = true; showCameraPanel = true } label: { Image(systemName:"slider.horizontal.3").frame(width:44,height:44) }.accessibilityLabel("Camera settings")
            cameraMenu
        }
        .padding(.horizontal, 20)
        .disabled(source == .iPhone && controlsBusy)
    }

    private var aspectButton: some View {
        Button { showAspect.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: source == .sony && sonyFullFrame ? "rectangle" : aspectSymbol(settings.aspect)).font(.system(size: 17))
                VStack(alignment: .leading, spacing: 0) {
                    Text(aspectTitle).font(.system(size: 13, weight: .semibold))
                    if rawEnabled {
                        Text("RAW").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(Palette.yellow)
                    }
                }
                Image(systemName: showAspect ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(showAspect ? Palette.yellow : Color.secondary)
            }.frame(minHeight: 44)
        }.accessibilityLabel("Aspect ratio and RAW options")
    }

    private var professionalStatus: some View {
        HStack(spacing:12) {
            if source == .iPhone {
                Menu {
                    ForEach(camera.controls.encodings.filter { !rawEnabled || camera.supportsProRAW || $0 == .jpeg }) { encoding in Button(encoding.rawValue) { settings.encoding = encoding } }
                    if camera.supportsRAW { Toggle(camera.supportsProRAW ? "ProRAW original" : "RAW original",isOn:rawBinding) }
                    Text("HEIF originals; edited/cropped derivatives may be JPEG")
                } label: {
                    Text((rawEnabled ? "RAW + " : "") + actualEncoding.rawValue).font(.system(.caption2,design:.monospaced,weight:.semibold))
                }.foregroundStyle(Palette.yellow).disabled(!camera.isRunning || controlsBusy)
                Button { camera.setControlMode(camera.controls.mode == .auto ? .pro : .auto) } label: {
                    Text(camera.controls.mode.rawValue).font(.system(.caption,design:.monospaced,weight:.semibold)).padding(.horizontal,10).frame(minHeight:34)
                        .background(camera.controls.mode == .pro ? Palette.yellow.opacity(0.15) : Palette.panel,in:Capsule())
                }.disabled(!camera.isRunning || controlsBusy).accessibilityLabel("Camera control mode \(camera.controls.mode.rawValue)")
            } else { Text(sony.hasFrame ? "SONY LIVE" : "SONY LINK").font(.system(.caption2,design:.monospaced)).foregroundStyle(Palette.yellow) }
            aspectButton
            Spacer(minLength:2)
            exposureButton
        }.padding(.horizontal,20)
    }
    private var actualEncoding: PhotoEncoding {
        if rawEnabled && !camera.supportsProRAW { return .jpeg }
        return camera.controls.encodings.contains(settings.encoding) ? settings.encoding : .jpeg
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
        Button { openSonyPanel = false; showCameraPanel = true } label: {
            Image(systemName: "ellipsis").font(.system(size: 21, weight: .bold)).frame(width: 44, height: 44)
        }.accessibilityLabel("Camera options").buttonStyle(CameraPressStyle())
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
            PrecisionOverlayView(reading:camera.precisionReading,options:precisionOptions,recommendations:camera.autoTuneRecommendations,apply:camera.applyAutoTune,canApply:camera.isCurrentAutoTuneRecommendation)
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            subjectOverlay
            coachOverlay
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .topLeading) { aspectOverlay }
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                if source == .iPhone && camera.controls.mode == .pro && hasLivePreview {
                    ProfessionalControlsView(camera:camera,busy:controlsBusy)
                } else if showExposure && hasLivePreview {
                    exposureStrip.transition(.move(edge: .bottom).combined(with: .opacity))
                } else if hasLivePreview && settings.guide {
                    CameraGuidanceCard(state: guideState, instruction: instruction, holdProgress: camera.framingHoldProgress, showHoldProgress: source == .iPhone && camera.framingPhase == .settling,
                                       composition:camera.compositionPlan.flatMap { $0.selected.isCurrentFrame ? nil : $0.selected.technique.rawValue })
                        .allowsHitTesting(false)
                }
                if source == .iPhone && (demo || camera.access == .available) { lensButtons }
            }.padding(.horizontal, 16).padding(.bottom, 12).padding(.top, 24)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
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
            onSelect: { camera.selectSubject(at: $0) },
            onZoom: { camera.setZoom($0) }, zoom: camera.zoom,
            onPinchBegin: { camera.beginManualZoom(completion: $0) }, mirrored: camera.isFrontCamera,
            showTapIndicator:camera.controls.canTapFocus && !camera.controls.manualFocus,
            onPreviewLayer:{ camera.attachAutofocusPreviewLayer($0) })
            .disabled(controlsBusy)
    }

    @ViewBuilder private var sonyPreview: some View {
        if sony.hasFrame {
            GeometryReader { geometry in
                SonyPreviewSurface(feed: sony.previewFeed)
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    .overlay(Color.clear.contentShape(Rectangle()).onTapGesture(coordinateSpace: .local) { (point: CGPoint) in
                        selectSonySubject(at: point, size: geometry.size)
                    })
            }
        } else {
            VStack(spacing: 15) {
                Image(systemName: "camera").font(.system(size: 40, weight: .light)).foregroundStyle(Palette.yellow)
                Text(sony.state == .reconnecting ? "Restoring Sony live view…" : "Sony Camera").font(.headline)
                if sony.state == .connecting || sony.state == .reconnecting { ProgressView().tint(Palette.yellow) }
                Button("Connect Sony camera") { openSonyPanel = true; showCameraPanel = true }
                    .buttonStyle(.borderedProminent).tint(Palette.yellow).foregroundStyle(.black)
                if let message = sony.message { Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3) }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func selectSonySubject(at point: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let visible = UnitPoint2D(x: Double(point.x / size.width), y: Double(point.y / size.height))
        camera.selectSubject(at: visible)
        let projection = PreviewProjection(imageAspect: sony.imageAspect, previewAspect: viewfinderAspect)
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
        if source == .sony { return sony.hasFrame }
        return !demo && camera.access == .available
    }

    @ViewBuilder private var subjectOverlay: some View {
        if hasLivePreview {
            CompositionOverlay(
                reading: reading, showGrid: settings.grid, guideEnabled: settings.guide,
                showLevel: settings.level && camera.levelReliable && source == .iPhone,
                subjectLabel: subjectName, framingPhase: camera.framingPhase, guidanceReady: camera.guidance.kind == .ready,
                showDirection:camera.guidance.showsDirection)
        }
    }

    @ViewBuilder private var coachOverlay: some View {
        if settings.guide && settings.coach && !showExposure && !showAspect && (source == .iPhone ? camera.isRunning : sony.hasFrame) {
            VStack(alignment: .leading, spacing: 3) {
                if let scene = camera.sceneLabel { Text("Frame label: \(scene)") }
                if let measured = camera.liveMeasurements {
                    Text(String(format: "Technical measure %.0f/100", measured.technicalScore))
                }
                if let alignment = reading.alignmentPercent(previewAspect: viewfinderAspect) {
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
        .disabled(source == .sony || demo || saving || camera.isCapturing || camera.framingPhase == .zooming || !camera.controls.evAdjustable)
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
            if source == .sony { sonyFrameOption }
            ForEach(PhotoAspect.allCases) { aspect in aspectOption(aspect) }.padding(.horizontal, 6)
            if camera.supportsRAW && source == .iPhone {
                Divider().overlay(Color.white.opacity(0.1)).padding(.horizontal,12).padding(.vertical,9)
                rawToggle
            }
        }.frame(width: 150).background(Color(white: 0.08).opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
    }

    private func aspectOption(_ aspect: PhotoAspect) -> some View {
        let selected: Bool = settings.aspect == aspect && !(source == .sony && sonyFullFrame)
        let foreground: Color = selected ? Color.white : Color.secondary
        let background: Color = selected ? Color.white.opacity(0.07) : Color.clear
        return Button { sonyFullFrame = false; settings.aspect = aspect; showAspect = false } label: {
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

    private var sonyFrameOption: some View {
        Button { sonyFullFrame = true; showAspect = false } label: {
            HStack {
                Image(systemName: "rectangle")
                Text("Camera frame").font(.system(size: 13))
                Spacer()
                if sonyFullFrame { Image(systemName: "checkmark").foregroundStyle(Palette.yellow) }
            }.padding(.horizontal, 14).frame(height: 34)
        }.foregroundStyle(.white)
    }

    private var rawToggle: some View {
        VStack(alignment:.leading,spacing:5) {
            Toggle(isOn: rawBinding) {
                HStack(spacing: 9) {
                    Image(systemName: "camera.aperture").foregroundStyle(Palette.yellow).font(.system(size: 13))
                    Text(camera.supportsProRAW ? "ProRAW" : "RAW").font(.system(size: 16, weight: .medium))
                }
            }.tint(Palette.yellow).controlSize(.mini).disabled(!camera.supportsRAW || controlsBusy || demo || source == .sony)
            if !camera.supportsRAW && !demo && source == .iPhone {
                Text(camera.rawUnavailableReason).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 14).padding(.bottom, 13)
    }

    private var guideState: CameraGuideState {
        CameraGuideState.resolve(enabled: settings.guide, reading: reading, phase: camera.framingPhase, message: camera.guidance)
    }
    private var footer: some View {
        VStack(spacing: 3) {
            if source == .sony && sony.hasFrame { SonyTelemetryStrip(telemetry: sony.telemetry).padding(.horizontal, 20) }
            captureButtons
        }.frame(maxHeight: .infinity).background(Palette.ink)
    }

    private var lensStops: [Double] {
        if source == .sony { return [] }
        return demo ? [1.0] : camera.zoomStops
    }

    private var lensButtons: some View {
        HStack(spacing: 8) {
            ForEach(lensStops, id: \.self) { stop in zoomButton(stop) }
        }.padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.72), in: Capsule()).frame(height: 43)
    }

    private func zoomButton(_ stop: Double) -> some View {
        let selected: Bool = closestStop == stop
        let label: String = zoomLabel(selected ? camera.zoom : stop)
        let foreground: Color = selected ? .black : .white.opacity(0.8)
        let background: Color = selected ? Palette.yellow : .clear
        return Button { camera.setZoom(stop) } label: {
            Text(label).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(foreground).frame(width: 34, height: 34)
                .background(background, in: Circle())
        }.buttonStyle(CameraPressStyle()).disabled(demo || controlsBusy).accessibilityLabel("Zoom \(zoomLabel(stop))")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var captureButtons: some View {
        HStack {
            Button { pauseActiveSource(); showLibrary = true } label: { libraryThumbnail }
                .accessibilityLabel("Open photo library").disabled(controlsBusy)
            Spacer()
            shutterButton
            Spacer()
            guidanceButton
        }.padding(.horizontal, 30).frame(height: 88)
    }

    private var shutterButton: some View {
        Button(action: shoot) {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 2.5).frame(width: 72, height: 72)
                Circle().fill(Color.white).frame(width: 62, height: 62)
                if saving || camera.isCapturing { ProgressView().tint(Color.black) }
            }.frame(width: 80, height: 80)
        }.buttonStyle(CameraPressStyle()).disabled(!canShoot).opacity(canShoot || saving ? 1 : 0.4).accessibilityLabel("Take photo")
    }

    private var guidanceButton: some View {
        Button { settings.guide.toggle(); UIImpactFeedbackGenerator(style: .soft).impactOccurred() } label: {
            VStack(spacing:4) {
                FocalIntelligenceMark().stroke(settings.guide ? Palette.ink : Palette.yellow,style:StrokeStyle(lineWidth:1.7,lineCap:.round,lineJoin:.round))
                    .frame(width:27,height:27).frame(width:50,height:50)
                    .background(settings.guide ? Palette.yellow : Palette.panel,in:Circle())
                    .overlay(Circle().stroke(Palette.yellow.opacity(settings.guide ? 1 : 0.4),lineWidth:1))
                Text(settings.guide ? "AI ON" : "AI OFF").font(.system(size:9,weight:.semibold,design:.monospaced)).foregroundStyle(Palette.muted)
            }
        }.buttonStyle(CameraPressStyle()).accessibilityLabel("Focal Intelligence")
            .accessibilityValue(settings.guide ? "On" : "Off")
            .accessibilityHint("Toggle composition guidance and automatic zoom")
            .animation(.easeInOut(duration: 0.18), value: settings.guide)
    }

    private var libraryThumbnail: some View {
        Group {
            if let photo = library.photos.first { PhotoImage(url: library.url(for: photo), maxPixels: 180, fill: true) }
            else { Image(systemName: "photo").font(.system(size: 19)).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.panel) }
        }.frame(width:48,height:48).clipped().clipShape(RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(.white.opacity(0.2),lineWidth:1))
    }

    private var instruction: String {
        if !seriesProgress.isEmpty { return seriesProgress }
        if saved { return "Saved to your library." }
        if demo { return "Demo scene. Enable AI Guidance to return to the camera." }
        if source == .sony && sony.state != .streaming { return (sony.state == .connecting || sony.state == .reconnecting) ? (sony.message ?? "Connecting to Sony…") : "Connect a Sony camera for guidance" }
        if !settings.guide { return "" }
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
        guard visible,scenePhase == .active,reviewPhoto == nil,!showCameraPanel else { return }
        if source == .iPhone { if !demo { camera.start() } }
        else { sony.resume() }
    }
    private func zoomLabel(_ value: Double) -> String {
        abs(value.rounded() - value) < 0.04 ? String(format: "%.0f×", value) : String(format: "%.1f×", value)
    }

    private func shoot() {
        guard canShoot else { return }
        showAspect = false; showExposure = false; saving = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let capturedSource = source
        let capturedDemo = demo && source == .iPhone
        let operation = UUID(); captureGeneration = operation
        let count = capturedDemo || source == .sony ? 1 : UserShutterPolicy.count(guidanceEnabled:settings.guide,requestedSeries:settings.burstCount)
        let wantsReview = capturedSource == .iPhone && count == 1 && settings.reviewAfterCapture
        let burst = count > 1 ? UUID() : nil
        let aspect = settings.aspect, caption = settings.caption
        let preserveSonyFrame = source == .sony && sonyFullFrame
        let savedAspect = preserveSonyFrame ? "Camera frame" : aspect.rawValue
        let keepRAW = settings.keepRAW, autoSave = settings.autoSaveToPhotos
        let scan = settings.saveScan && settings.guide && !demo ? camera.scanData : nil
        let label: String? = settings.guide && !demo && reading.subjectBounds != nil ? subjectName : nil
        let capturedMode = settings.guide ? (mode == .automatic ? camera.compositionPlan?.selected.technique.rawValue ?? mode.rawValue : mode.rawValue) : "Free shoot"
        let capturedIntent = settings.intent.rawValue
        let challenge = settings.challenge.isEmpty ? nil : settings.challenge
        let options = CaptureOptions(raw:rawEnabled,flash:settings.flash,shutterSound:settings.shutterSound,encoding:actualEncoding)
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
                        let processed = preserveSonyFrame ? capture.processed : try PhotoRenderer.crop(capture.processed,to: aspect)
                        return (processed, index == 0 ? scan.flatMap { PhotoRenderer.captionedScan($0,style: caption) } : nil)
                    }.value
                    try Task.checkCancellation()
                    let photo = try await library.add(data: rendered.0,mode: capturedMode,isDemo: capturedDemo,
                        rawData: keepRAW ? capture.raw : nil,originalData: rendered.0 == capture.processed ? nil : capture.processed,
                        scanData: rendered.1,aspect: savedAspect,subject: label,challenge: challenge,burstID: burst,cameraOrigin: capturedSource.rawValue,photographyIntent:capturedIntent,framedCapture:capture.framing)
                    added.append(photo)
                    if index+1 < count { try await Task.sleep(for: .milliseconds(180)) }
                }
                if autoSave && !wantsReview {
                    for photo in added {
                        do { try await library.saveToPhotos(photo) }
                        catch { camera.errorMessage = "Saved in Focal. Photos export: \(error.localizedDescription)"; break }
                    }
                }
                if operation == captureGeneration {
                    saved = !added.isEmpty
                    if wantsReview, let photo = added.first {
                        reviewAutoSave = autoSave; pauseActiveSource(); reviewPhoto = photo
                    }
                }
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
