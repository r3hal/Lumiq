import SwiftUI
import CoreImage

struct PhotoEditorView: View {
    let photo: SavedPhoto
    var captureReview = false
    var autoSaveOnReview = false
    @EnvironmentObject private var library: PhotoLibrary
    @EnvironmentObject private var recipes: RecipeStore
    @Environment(\.dismiss) private var dismiss
    @State private var recipe = EditRecipe.original
    @State private var history = EditHistory()
    @State private var source: CIImage?
    @State private var sourceURL: URL?
    @State private var preview: UIImage?
    @State private var before: UIImage?
    @State private var thumbs = [FilmPreset: UIImage]()
    @State private var tab: EditorTab = .looks
    @State private var tool: EditorTool = .exposure
    @State private var option = 0
    @State private var channel = 0
    @State private var compare = false
    @State private var saving = false
    @State private var loadFailed = false
    @State private var usingRAW = false
    @State private var tryingRAW = false
    @State private var message: String?
    @State private var showName = false
    @State private var confirmDelete = false
    @State private var name = ""
    @State private var renderedRecipe: EditRecipe?

    var body: some View {
        editorLifecycle
            .alert("Photo editor", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
            .alert("Save recipe", isPresented: $showName) {
                TextField("Recipe name", text: $name)
                Button("Save") { do { try recipes.save(name: name, recipe: recipe) } catch { message = error.localizedDescription } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete this capture and its originals from Focal?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    do { try library.delete(library.photos.first { $0.id == photo.id } ?? photo); dismiss() }
                    catch { message = error.localizedDescription }
                }
            }
    }
    private var editorLifecycle: some View {
        editorLayout.task { await load() }
            .task(id: PreviewKey(recipe: recipe, loaded: source != nil, raw: usingRAW)) { await renderPreview() }
            .task(id: before != nil) { await renderThumbnails() }
            .interactiveDismissDisabled(saving)
    }
    private var editorLayout: some View {
        VStack(spacing: 12) {
            topBar
            photoCanvas.frame(maxWidth: .infinity, maxHeight: .infinity)
            tabStrip.disabled(!photo.canUsePhoneEditor)
            controlPanel.frame(height: 174).disabled(!photo.canUsePhoneEditor)
            bottomBar.padding(.bottom, 8).disabled(!photo.canUsePhoneEditor)
        }.padding(.horizontal, 16).background(Palette.ink).foregroundStyle(.white).tint(Palette.yellow)
            .disabled(saving)
    }
    private var topBar: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 32, height: 30) }.disabled(saving)
            Spacer()
            if usingRAW { Text("RAW").font(.system(size: 9, weight: .semibold)).padding(4).overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.5))) }
            Spacer()
            editMenu.disabled(!photo.canUsePhoneEditor)
        }.foregroundStyle(.white.opacity(0.7)).padding(.top, 5)
    }
    @ViewBuilder private var photoCanvas: some View {
        if !photo.canUsePhoneEditor { ContentUnavailableView("iPhone editing only", systemImage: "iphone", description: Text("Sony photos keep their camera output.")) }
        else if let image = compare ? before : preview {
            Image(uiImage: image).resizable().scaledToFit()
                .onLongPressGesture(minimumDuration: 0.05, pressing: { compare = $0 }, perform: {})
                .accessibilityLabel(compare ? "Original photo" : "Edited photo preview")
        } else if loadFailed { ContentUnavailableView("Photo unavailable", systemImage: "photo.badge.exclamationmark") }
        else { ProgressView(tryingRAW ? "Developing RAW…" : "Preparing your photo…").tint(Palette.yellow) }
    }
    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(EditorTab.allCases) { item in
                Button { tab = item; if item == .effects { tool = .grain; option = 0; channel = 0 } else if item == .adjust { tool = .exposure; option = 0; channel = 0 } } label: {
                    Text(item.rawValue).font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 7)
                        .foregroundStyle(tab == item ? .white : .secondary)
                        .background(tab == item ? Color(white: 0.23) : .clear, in: Capsule())
                }.accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }.padding(3).background(Color(white: 0.07), in: Capsule())
    }
    @ViewBuilder private var controlPanel: some View {
        switch tab {
        case .looks: looksPanel
        case .adjust, .effects: adjustmentsPanel
        case .frames: framesPanel
        }
    }
    private var looksPanel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(FilmPreset.allCases) { preset in lookButton(preset) }
            }.padding(.vertical, 8)
        }
    }
    private func lookButton(_ preset: FilmPreset) -> some View {
        let selected = recipe.lookName == preset.rawValue || (recipe.lookName == nil && preset == .original)
        return Button {
            var next = preset.recipe; next.lookName = preset == .original ? nil : preset.rawValue
            next.crop = recipe.crop; next.quarterTurns = recipe.quarterTurns; next.frame = recipe.frame
            next.dateStamp = recipe.dateStamp; next.stampDate = recipe.stampDate
            apply(next)
        } label: {
            VStack(spacing: 7) {
                Group {
                    if let image = thumbs[preset] { Image(uiImage: image).resizable().scaledToFill() }
                    else { Rectangle().fill(Color(white: 0.12)).overlay(ProgressView().scaleEffect(0.6)) }
                }.frame(width: 65, height: 90).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Palette.yellow : .clear, lineWidth: 1.5))
                Text(preset.rawValue.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(selected ? Palette.yellow : .secondary)
            }
        }.accessibilityLabel(preset.rawValue + " look").accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var parameters: [EditorParameter] { EditorParameter.choices(for: tool) }
    private var parameter: EditorParameter { parameters[min(option, parameters.count - 1)] }
    private var parameterBinding: Binding<Double> {
        Binding(get: { parameter.value(in: recipe, channel: channel) }, set: { parameter.set($0, in: &recipe, channel: channel) })
    }
    private var adjustmentsPanel: some View {
        VStack(spacing: 5) {
            channelStrip
            parameterStrip
            EditorRuler(value: parameterBinding, range: parameter.range, title: tool.rawValue + " " + parameter.title,
                        begin: {}, commit: { history.set(recipe); recipe = history.current })
            toolStrip
        }
    }
    @ViewBuilder private var channelStrip: some View {
        if tool == .hsl {
            HStack(spacing: 12) {
                ForEach(0..<8, id: \.self) { index in
                    let hues = [0.0, 0.083, 0.167, 0.333, 0.5, 0.667, 0.75, 0.833]
                    Button { channel = index } label: {
                        Circle().fill(Color(hue: hues[index], saturation: 0.8, brightness: 0.9)).frame(width: 17, height: 17)
                            .overlay(Circle().stroke(channel == index ? .white : .clear, lineWidth: 2).padding(-3))
                    }.accessibilityLabel(["Red", "Orange", "Yellow", "Green", "Cyan", "Blue", "Purple", "Magenta"][index])
                }
            }.padding(.vertical, 3)
        } else if tool == .grading || tool == .calibration {
            HStack {
                ForEach(0..<3, id: \.self) { index in
                    Button { channel = index } label: {
                        Text(tool == .grading ? ["Shadows", "Midtones", "Highlights"][index] : ["Red", "Green", "Blue"][index])
                            .font(.system(size: 10)).foregroundStyle(channel == index ? Palette.yellow : .secondary)
                    }
                }
            }
        }
    }
    private var parameterStrip: some View {
        HStack(spacing: 8) {
            ForEach(parameters.indices, id: \.self) { index in
                Button { option = index } label: {
                    Text(parameters[index].title + (option == index ? "  " + valueLabel : ""))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(option == index ? .white : .secondary)
                        .padding(.horizontal, 9).padding(.vertical, 4).background(option == index ? Color(white: 0.16) : .clear, in: Capsule())
                }
            }
        }.frame(height: 25)
    }
    private var valueLabel: String {
        let value = parameter.value(in: recipe, channel: channel)
        return parameter == .exposure ? String(format: "%.1f", value) : String(format: "%.0f", value * 100)
    }
    private var toolStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 15) {
                ForEach(EditorTool.allCases.filter { $0.isEffect == (tab == .effects) }) { item in
                    Button { history.set(recipe); tool = item; option = 0; channel = 0 } label: {
                        VStack(spacing: 6) {
                            Image(systemName: item.symbol).font(.system(size: 17)).frame(width: 35, height: 35)
                                .background(Color(white: 0.07), in: Circle()).overlay(Circle().stroke(tool == item ? .white.opacity(0.8) : .clear, lineWidth: 1))
                            Text(item.rawValue).font(.system(size: 9)).lineLimit(1)
                        }.foregroundStyle(tool == item ? .white : .secondary)
                    }.accessibilityAddTraits(tool == item ? .isSelected : [])
                }
            }
        }
    }
    private var framesPanel: some View {
        VStack(spacing: 15) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(PhotoFrame.allCases) { frame in
                        Button { var next = recipe; next.frame = frame; apply(next) } label: {
                            VStack(spacing: 8) {
                                frameIcon(frame).frame(width: 38, height: 44).padding(5)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(recipe.frame == frame ? Palette.yellow : .clear, lineWidth: 1.5))
                                Text(frame.rawValue).font(.system(size: 10)).foregroundStyle(recipe.frame == frame ? Palette.yellow : .secondary)
                            }
                        }.accessibilityLabel(frame.rawValue + " frame")
                    }
                }
            }
            Toggle("Date stamp", isOn: Binding(get: { recipe.dateStamp }, set: { value in
                var next = recipe; next.dateStamp = value; next.stampDate = value ? photo.createdAt : nil; apply(next)
            })).font(.caption).toggleStyle(.switch).tint(Palette.yellow).fixedSize()
        }
    }
    private func frameIcon(_ frame: PhotoFrame) -> some View {
        ZStack {
            Rectangle().fill(frame == .none || frame == .black ? .black : frame == .paper || frame == .negative ? Color(white: 0.87) : .white)
            Rectangle().fill(Color(white: 0.23)).padding(frame == .none ? 0 : 6).padding(.bottom, frame == .instant || frame == .specs ? 6 : 0)
        }
    }
    private var bottomBar: some View {
        HStack(spacing: 20) {
            Button("Delete") { confirmDelete = true }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 21).frame(height: 38).background(Color(white: 0.1), in: Capsule())
            Spacer()
            Button { history.undo(); recipe = history.current } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!history.canUndo)
            Button { history.redo(); recipe = history.current } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!history.canRedo)
            Spacer()
            Button { save() } label: {
                HStack(spacing: 5) { if saving { ProgressView().tint(.black) } else { Image(systemName: "checkmark") }; Text(saving ? "Saving…" : "Save") }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.black).padding(.horizontal, 19).frame(height: 38).background(Palette.yellow, in: Capsule())
            }.disabled(saving || source == nil || renderedRecipe != recipe.normalized)
        }.foregroundStyle(.white)
    }
    private var editMenu: some View {
        Menu {
            Button("Compare with original") { compare.toggle() }
            Button("Reset all") { apply(.original) }
            Button("Rotate 90°") { var next = recipe; next.quarterTurns += 1; apply(next) }
            Menu("Crop") {
                Button("Keep frame") { var next = recipe; next.crop = nil; apply(next) }
                ForEach(PhotoAspect.allCases) { aspect in Button(aspect.rawValue) { var next = recipe; next.crop = aspect; apply(next) } }
            }
            Button("Save recipe") { name = ""; showName = true }
            ForEach(recipes.recipes) { saved in Button(saved.name) { apply(saved.recipe) } }
            if !recipes.recipes.isEmpty {
                Menu("Delete saved recipe") {
                    ForEach(recipes.recipes) { saved in
                        Button(saved.name, role: .destructive) {
                            do { try recipes.delete(saved.id) } catch { message = error.localizedDescription }
                        }
                    }
                }
            }
        } label: { Image(systemName: "ellipsis").frame(width: 32, height: 30) }
    }
    private struct PreviewKey: Hashable { let recipe: EditRecipe; let loaded: Bool; let raw: Bool }
    private func apply(_ value: EditRecipe) { history.set(value); recipe = history.current }
    private func load() async {
        guard photo.canUsePhoneEditor else { loadFailed = true; return }
        let jpegURL = library.editingSourceURL(for: photo)
            ?? (photo.editingRecipe != nil ? library.originalURL(for: photo) : nil)
            ?? library.url(for: photo)
        let rawURL = library.rawURL(for: photo)
        let attemptRAW = rawURL != nil && (captureReview || photo.editingRecipe == nil || photo.developedFromRAW == true)
        tryingRAW = attemptRAW
        let loaded = await Task.detached(priority: .userInitiated) { () -> (CIImage?, Bool) in
            if attemptRAW, let rawURL, let filter = CIRAWFilter(imageURL: rawURL), let raw = filter.outputImage { return (raw, true) }
            return (CIImage(contentsOf: jpegURL, options: [.applyOrientationProperty: true]), false)
        }.value
        guard !Task.isCancelled else { return }
        usingRAW = loaded.1; source = loaded.0; sourceURL = jpegURL
        var edit = photo.editingRecipe ?? .original
        if usingRAW && photo.editingRecipe == nil { edit.crop = photo.aspect.flatMap(PhotoAspect.init(rawValue:)) }
        apply(edit); loadFailed = loaded.0 == nil
    }
    private func renderPreview() async {
        guard let input = source else { return }
        let edit = recipe.normalized
        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        let result = await Task.detached(priority: .userInitiated) { ImageEditor.preview(source: input, recipe: edit) }.value
        guard !Task.isCancelled else { return }
        if result == nil && usingRAW, let sourceURL {
            source = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true]); usingRAW = false
            message = "RAW is kept, but this RAW preview could not be developed. Editing the camera JPEG instead."; return
        }
        preview = result; renderedRecipe = result == nil ? nil : edit; loadFailed = result == nil; tryingRAW = false
        if before == nil {
            let baseline = EditRecipe(crop: usingRAW ? photo.aspect.flatMap(PhotoAspect.init(rawValue:)) : nil)
            let original = await Task.detached { ImageEditor.preview(source: input, recipe: baseline) }.value
            guard !Task.isCancelled else { return }; before = original
        }
    }
    private func renderThumbnails() async {
        guard let cg = before?.cgImage else { return }
        let thumbSource = CIImage(cgImage: cg)
        let result = await Task.detached(priority: .utility) { () -> [FilmPreset: UIImage] in
            var images = [FilmPreset: UIImage]()
            for preset in FilmPreset.allCases { autoreleasepool { images[preset] = ImageEditor.preview(source: thumbSource, recipe: preset.recipe, maxPixels: 150) } }
            return images
        }.value
        guard !Task.isCancelled else { return }; thumbs = result
    }
    private func save() {
        guard photo.canUsePhoneEditor, let source, let sourceURL else { return }
        saving = true; let edit = recipe.normalized, raw = usingRAW
        let rawURL = library.rawURL(for: photo)
        Task {
            do {
                let bytes = try await Task.detached(priority: .userInitiated) {
                    raw ? try ImageEditor.export(source: source, recipe: edit) : try ImageEditor.export(data: Data(contentsOf: sourceURL), recipe: edit)
                }.value
                let saved: SavedPhoto
                if captureReview { saved = try await library.finishPhoneReview(photo, data: bytes, recipe: edit, developedFromRAW: raw) }
                else {
                    let originals = try await Task.detached { () -> (Data, Data?) in
                        let jpeg = try Data(contentsOf: sourceURL)
                        let rawData: Data?
                        if raw, let rawURL { rawData = try Data(contentsOf: rawURL) } else { rawData = nil }
                        return (jpeg, rawData)
                    }.value
                    saved = try await library.add(data: bytes, mode: "Edited", isDemo: photo.isDemo, rawData: originals.1, originalData: originals.0,
                        aspect: edit.crop?.rawValue ?? photo.aspect, subject: photo.subject, cameraOrigin: photo.cameraOrigin, editingRecipe: edit, developedFromRAW: raw)
                    if let collection = photo.collection { library.setCollection(collection, for: saved) }
                }
                if captureReview && autoSaveOnReview {
                    do { try await library.saveToPhotos(saved) }
                    catch { message = "Saved in Focal. Photos export: " + error.localizedDescription; saving = false; return }
                }
                dismiss()
            } catch { message = error.localizedDescription; saving = false }
        }
    }
}
