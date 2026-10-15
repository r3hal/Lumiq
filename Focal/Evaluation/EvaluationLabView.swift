#if DEBUG || FOCAL_EVALUATION
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct EvaluationLabView: View {
    @StateObject private var store = EvaluationStore()
    @ObservedObject var camera: CameraController
    @State private var picker: PhotosPickerItem?
    @State private var editing: EvaluationSample?
    @State private var importing = false
    @State private var exportURL: URL?
    @State private var framingTraceURL: URL?
    var body: some View {
        List {
            Section {
                Text("Developer evaluation · local images and labels only. Imports are normalized to 1024px JPEG; originals remain unchanged. No training or upload.").font(.caption)
                PhotosPicker(selection:$picker,matching:.images) { Label("Import test photo",systemImage:"photo.badge.plus") }.disabled(store.running)
                Button("Add landscape starter example") { Task { do { try await store.seedLandscape() } catch { store.message = error.localizedDescription } } }.disabled(store.running)
                Button("Import evaluation JSON") { importing = true }.disabled(store.running)
                Button(store.running ? "Cancel evaluation" : "Evaluate labeled examples") { if store.running { store.cancel() } else { store.evaluate() } }
                if store.running { ProgressView("Running paired on-device analysis…") }
                Button("Prepare self-contained JSON export") { Task { do { exportURL = try await store.export(performance:camera.guidancePerformance) } catch { store.message = error.localizedDescription } } }.disabled(store.running)
                if let exportURL { ShareLink("Share images, labels and results",item:exportURL) }
                if let message = store.message { Text(message).font(.caption).foregroundStyle(.red) }
            } header: { Text("Focal Intelligence Lab") }
            framingDiagnostics
            if let timing = camera.guidancePerformance {
                Section {
                    Text("\(timing.source) · \(timing.sampleCount) real analysis updates").font(.caption)
                    if let ms = timing.meanInferenceMilliseconds { Text(String(format:"Vision mean %.1f ms",ms)).font(.caption) }
                    if let ms = timing.meanObservationAgeMilliseconds { Text(String(format:"Observation age mean %.1f ms",ms)).font(.caption) }
                    if let hz = timing.updatesPerSecond { Text(String(format:"Guidance %.2f updates/second",hz)).font(.caption) }
                    Text("Stale results rejected: \(timing.staleRejections) · thermal: \(timing.thermalState)").font(.caption)
                    Text(timing.notes).font(.caption2)
                } header: { Text("Measured live diagnostics") }
            }
            Section {
                ForEach(store.samples) { sample in
                    Button { editing = sample } label: {
                        HStack {
                            if let image = UIImage(contentsOfFile:store.directory.appendingPathComponent(sample.imageFile).path) { Image(uiImage:image).resizable().scaledToFill().frame(width:48,height:48).clipped() }
                            VStack(alignment:.leading) {
                                Text(sample.annotation.mainSubject.isEmpty ? sample.annotation.intent.rawValue+" scene" : sample.annotation.mainSubject)
                                Text(sample.annotation.reviewed ? "Labeled" : "Needs labels").font(.caption).foregroundStyle(Palette.muted)
                            }
                        }
                    }.disabled(store.running)
                }
            } header: { Text("Examples (\(store.samples.count))") }
            if let report = store.report {
                EvaluationResultsSection(report:report,feedback:{ id,label in
                    do { try store.addFeedback(label,for:id); exportURL = nil } catch { store.message = error.localizedDescription }
                }).disabled(store.running)
            }
        }.scrollContentBackground(.hidden).background(Palette.ink).foregroundStyle(Palette.text).tint(Palette.yellow)
            .navigationTitle("Intelligence Lab").navigationBarTitleDisplayMode(.inline)
            .sheet(item:$editing) { sample in EvaluationAnnotationView(sample:sample,directory:store.directory,save:{ annotation in
                do { try store.save(annotation,for:sample.id); exportURL = nil } catch { store.message = error.localizedDescription }
            }) }
            .fileImporter(isPresented:$importing,allowedContentTypes:[.json]) { result in
                Task { do { let url = try result.get(); try await store.importDataset(url); exportURL = nil } catch { store.message = error.localizedDescription } }
            }
            .task(id:picker) {
                guard let picker else { return }
                do { if let data = try await picker.loadTransferable(type:Data.self) { try await store.addImage(data); exportURL = nil } }
                catch { store.message = error.localizedDescription }
            }.onDisappear { store.cancel() }
    }
    private var framingDiagnostics: some View {
        Section {
            Button("Prepare AI framing trace") {
                do { framingTraceURL = try ShotFramingDiagnostics.export() }
                catch { store.message = error.localizedDescription }
            }
            if let framingTraceURL { ShareLink("Share AI framing trace",item:framingTraceURL) }
            Text("Recent session states, gates and actual zoom readings. No images. Reproduce the shot before exporting.")
                .font(.caption)
        } header: { Text("Shot Director diagnostics") }
    }
}

private struct EvaluationAnnotationView: View {
    let sample: EvaluationSample
    let directory: URL
    let save: (EvaluationAnnotation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var annotation: EvaluationAnnotation
    @State private var draft: CGRect?
    @State private var start: CGPoint?
    @State private var manualBox = false
    @State private var error: String?
    init(sample:EvaluationSample,directory:URL,save:@escaping (EvaluationAnnotation)->Void) {
        self.sample = sample; self.directory = directory; self.save = save; _annotation = State(initialValue:sample.annotation)
    }
    var body: some View {
        NavigationStack {
            Form {
                if let image = UIImage(contentsOfFile:directory.appendingPathComponent(sample.imageFile).path) {
                    imageAnnotation(image)
                }
                labelFields
                regionFields
            }.scrollContentBackground(.hidden).background(Palette.ink).navigationTitle("Label example").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) { Button("Save labels") {
                        guard (annotation.expectsNoObject || !annotation.mainSubject.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty), annotation.acceptableComposition != nil, annotation.preferredAction != nil, annotation.framingIssue != "Unlabeled" else { error = "Label the subject/no-object case, composition, issue and preferred action before evaluation."; return }
                        guard annotation.sequenceTime.map({ $0.isFinite && $0 >= 0 }) ?? true else { error = "Use a finite non-negative sequence time."; return }
                        annotation.reviewed = true; save(annotation); dismiss()
                    } }
                }
        }.tint(Palette.yellow).preferredColorScheme(.dark)
    }
    private var labelFields: some View {
                Section {
                    Toggle("No object box is needed",isOn:$annotation.expectsNoObject)
                    Picker("Dataset split",selection:Binding(get:{ annotation.datasetSplit ?? "calibration" },set:{ annotation.datasetSplit = $0 })) {
                        Text("Calibration").tag("calibration"); Text("Held-out evaluation").tag("held-out")
                    }
                    Picker("Automatic crop appropriate",selection:Binding(get:{ annotation.automaticZoomAppropriate.map { $0 ? 1 : 2 } ?? 0 },set:{ annotation.automaticZoomAppropriate = $0 == 0 ? nil : $0 == 1 })) {
                        Text("Unlabeled").tag(0); Text("Yes").tag(1); Text("No").tag(2)
                    }
                    Toggle("Intentional unconventional framing",isOn:Binding(get:{ annotation.intentionallyUnconventional ?? false },set:{ annotation.intentionallyUnconventional = $0 }))
                    TextField("Main subject",text:$annotation.mainSubject).disabled(annotation.expectsNoObject)
                    Picker("Intent",selection:$annotation.intent) { ForEach(PhotographyIntent.allCases) { Text($0.rawValue).tag($0) } }
                    if annotation.intent == .pet {
                        Picker("Pet framing input",selection:Binding(get:{ annotation.petStyle ?? .balanced },set:{ annotation.petStyle = $0 })) {
                            ForEach(PetFramingStyle.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    Picker("Acceptable composition",selection:Binding(get:{ annotation.acceptableComposition.map { $0 ? 1 : 2 } ?? 0 },set:{ annotation.acceptableComposition = $0 == 0 ? nil : $0 == 1 })) {
                        Text("Unlabeled").tag(0); Text("Yes").tag(1); Text("No").tag(2)
                    }
                    Picker("Main issue",selection:$annotation.framingIssue) {
                        ForEach(["Unlabeled","None","Frame edge","Too small","Placement","Exposure","Motion","Background","Perspective","Uncertain"],id:\.self) { Text($0).tag($0) }
                    }
                    Picker("Preferred recommendation",selection:Binding(get:{ annotation.preferredAction?.rawValue ?? "Unlabeled" },set:{ annotation.preferredAction = GuidanceAction(rawValue:$0) })) {
                        Text("Unlabeled").tag("Unlabeled")
                        ForEach(GuidanceAction.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                } header: { Text("Human reference labels") }
    }
    private var regionFields: some View {
                Section {
                    Toggle("Draw a manual selection input instead of a reference box",isOn:$manualBox)
                    Text("Drag on the photo to mark the main subject. The reference box is ground truth only; it never steers automatic predictions. Manual selection is a separate optional engine input.").font(.caption)
                    Button("Clear reference box") { annotation.expectedBounds = nil; draft = nil }
                    Button("Clear manual selection") { annotation.manualSelection = nil; draft = nil }
                    TextField("Sequence ID (optional)",text:Binding(get:{ annotation.sequenceID ?? "" },set:{ annotation.sequenceID = $0.isEmpty ? nil : $0 }))
                    TextField("Seconds in sequence (optional)",text:Binding(get:{ annotation.sequenceTime.map { String($0) } ?? "" },set:{ annotation.sequenceTime = Double($0) })).keyboardType(.decimalPad)
                    TextField("Notes",text:$annotation.notes,axis:.vertical)
                    Text(sample.provenance).font(.caption2)
                    if let error { Text(error).foregroundStyle(.red) }
                } header: { Text("Regions and sequences") }
    }
    private func imageAnnotation(_ image:UIImage) -> some View {
        Image(uiImage:image).resizable().aspectRatio(image.size.width/image.size.height,contentMode:.fit)
            .overlay { GeometryReader { geometry in
                let rect = draft ?? (manualBox ? annotation.manualSelection?.cgRect : annotation.expectedBounds?.cgRect)
                if let rect { Rectangle().stroke(manualBox ? Palette.mint : Palette.yellow,lineWidth:2).frame(width:rect.width*geometry.size.width,height:rect.height*geometry.size.height).position(x:rect.midX*geometry.size.width,y:rect.midY*geometry.size.height) }
                Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged { value in
                    let width = max(1,geometry.size.width),height = max(1,geometry.size.height)
                    if start == nil { start = CGPoint(x:max(0,min(1,value.startLocation.x/width)),y:max(0,min(1,value.startLocation.y/height))) }
                    let point = CGPoint(x:max(0,min(1,value.location.x/width)),y:max(0,min(1,value.location.y/height)))
                    if let start { draft = CGRect(x:min(start.x,point.x),y:min(start.y,point.y),width:abs(point.x-start.x),height:abs(point.y-start.y)) }
                }.onEnded { _ in
                    if let draft, draft.width > 0.005, draft.height > 0.005 {
                        if manualBox { annotation.manualSelection = EvaluationRect(draft) } else { annotation.expectedBounds = EvaluationRect(draft) }
                    }
                    start = nil; draft = nil
                })
            } }.listRowInsets(EdgeInsets())
    }
}

private struct EvaluationResultsSection: View {
    let report: EvaluationReport
    let feedback: (UUID,EvaluationFeedbackLabel) -> Void
    var body: some View {
        Section {
            Text("Intelligence 3.0 / 4.0 recommendations").font(.headline)
            if let rate = report.updatedMetrics.autoZoomMistakes {
                Text("Unwanted static crop proposals: \(rate.numerator)/\(rate.denominator)").font(.caption)
            }
            if let value = report.updatedMetrics.meanSelectionOverlap { Text("Sequence box overlap: \(value,format:.number.precision(.fractionLength(2))) · not tracking accuracy").font(.caption) }
            if let old = report.heldOutBaselineMetrics, let new = report.heldOutUpdatedMetrics {
                Text("Held-out unnecessary adjustments: \(old.unnecessaryRecommendations.numerator)/\(old.unnecessaryRecommendations.denominator) → \(new.unnecessaryRecommendations.numerator)/\(new.unnecessaryRecommendations.denominator)").font(.caption)
            }
            metric("Detection agreement",report.baselineMetrics.detectionAgreement,report.updatedMetrics.detectionAgreement)
            metric("Selection agreement",report.baselineMetrics.selectionAgreement,report.updatedMetrics.selectionAgreement)
            metric("Recommendation agreement",report.baselineMetrics.recommendationAgreement,report.updatedMetrics.recommendationAgreement)
            metric("Unnecessary adjustments ↓",report.baselineMetrics.unnecessaryRecommendations,report.updatedMetrics.unnecessaryRecommendations)
            metric("Contradictions ↓",report.baselineMetrics.contradictions,report.updatedMetrics.contradictions)
            metric("Sequence stability",report.baselineMetrics.stability,report.updatedMetrics.stability)
            if let time = report.updatedMetrics.meanInferenceMilliseconds { Text(String(format:"Current shared analysis %.1f ms/image mean",time)).font(.caption) }
            Text(report.notes).font(.caption2).foregroundStyle(Palette.muted)
            ForEach(report.errors,id:\.self) { Text($0).font(.caption).foregroundStyle(.red) }
            ForEach(report.updated.indices,id:\.self) { index in
                let result = report.updated[index]
                VStack(alignment:.leading,spacing:4) {
                    Text(result.selected?.label ?? "Scene / no selected object").font(.caption.weight(.semibold))
                    Text("New: "+(result.text.isEmpty ? "No recommendation" : result.text)).font(.caption)
                    if let time = result.pairedDecisionMilliseconds { Text(String(format:"Paired decision stages %.2f ms",time)).font(.caption2) }
                    Menu("Label this evaluated recommendation") {
                        ForEach(EvaluationFeedbackLabel.allCases) { label in
                            Button(label.rawValue) { feedback(result.sampleID,label) }
                        }
                    }
                    if let old = report.baseline.first(where: { $0.sampleID == result.sampleID }) { Text("Old: "+old.text).font(.caption).foregroundStyle(Palette.muted) }
                }
            }
        } header: { Text("Measured evaluation results") }
    }
    private func metric(_ name:String,_ baseline:EvaluationRate,_ updated:EvaluationRate) -> some View {
        VStack(alignment:.leading,spacing:3) {
            Text(name).font(.caption.weight(.semibold))
            Text(value(baseline)+" / "+value(updated)).font(.system(.caption,design:.monospaced))
        }
    }
    private func value(_ rate:EvaluationRate) -> String {
        rate.value.map { String(format:"%.0f%% (%d/%d)",$0*100,rate.numerator,rate.denominator) } ?? "Not measured"
    }
}
#endif
