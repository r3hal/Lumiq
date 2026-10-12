import SwiftUI
import CoreImage

struct PhotoEditorView: View {
    let photo: SavedPhoto
    @EnvironmentObject private var library: PhotoLibrary
    @EnvironmentObject private var recipes: RecipeStore
    @Environment(\.dismiss) private var dismiss
    @State private var recipe = EditRecipe.original
    @State private var source: CIImage?
    @State private var preview: UIImage?
    @State private var before: UIImage?
    @State private var compare = false
    @State private var saving = false
    @State private var loadFailed = false
    @State private var message: String?
    @State private var showName = false
    @State private var name = ""
    @State private var renderedRecipe: EditRecipe?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Group {
                        if let image = compare ? before : preview { Image(uiImage: image).resizable().scaledToFit() }
                        else if loadFailed { ContentUnavailableView("Photo unavailable",systemImage: "photo.badge.exclamationmark") }
                        else { ProgressView("Rendering preview…").frame(height: 250) }
                    }.frame(maxHeight: 400).clipShape(RoundedRectangle(cornerRadius: 14))
                    Toggle("Compare with original", isOn: $compare)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(FilmPreset.allCases) { preset in
                                Button(preset.rawValue) { recipe = preset.recipe }.buttonStyle(.bordered)
                            }
                        }
                    }
                    if !recipes.recipes.isEmpty {
                        Menu("My recipes") {
                            ForEach(recipes.recipes) { saved in
                                Button(saved.name) { recipe = saved.recipe }
                                Button("Delete \(saved.name)", role: .destructive) { do { try recipes.delete(saved.id) } catch { message = error.localizedDescription } }
                            }
                        }
                    }
                    adjustment("Exposure", value: $recipe.exposure, range: -3...3)
                    adjustment("Contrast", value: $recipe.contrast, range: 0.5...1.5)
                    adjustment("Saturation", value: $recipe.saturation, range: 0...2)
                    adjustment("Warmth", value: $recipe.warmth, range: -1...1)
                    adjustment("Highlights", value: $recipe.highlights, range: 0...2)
                    adjustment("Shadows", value: $recipe.shadows, range: 0...1)
                    adjustment("Grain", value: $recipe.grain, range: 0...1)
                    adjustment("Vignette", value: $recipe.vignette, range: 0...2)
                    Picker("Crop", selection: $recipe.crop) {
                        Text("Keep frame").tag(Optional<PhotoAspect>.none)
                        ForEach(PhotoAspect.allCases) { aspect in Text(aspect.rawValue).tag(Optional(aspect)) }
                    }
                    HStack {
                        Button("Rotate 90°", systemImage: "rotate.right") { recipe.quarterTurns = (recipe.quarterTurns + 1) % 4 }
                        Spacer()
                        Button("Reset") { recipe = .original }
                    }
                    Button("Save recipe") { name = ""; showName = true }.buttonStyle(.bordered)
                    Text("Edits save a new full-resolution photo. Your original and RAW remain untouched. Preview is smaller for smooth editing.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.background(.black).disabled(saving)
                .navigationTitle("Edit photo").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(saving ? "Saving…" : "Save copy") { save() }.disabled(saving || source == nil || renderedRecipe != recipe)
                    }
                }
                .task {
                    let url = library.url(for: photo)
                    let image = await Task.detached(priority: .userInitiated) { CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) }.value
                    guard !Task.isCancelled else { return }
                    source = image
                    if image == nil { loadFailed = true; message = "This photo could not be opened." }
                }
                .task(id: PreviewKey(recipe: recipe, loaded: source != nil)) {
                    guard let source else { return }
                    let edit = recipe
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    let result = await Task.detached(priority: .userInitiated) { ImageEditor.preview(source: source, recipe: edit) }.value
                    guard !Task.isCancelled else { return }
                    preview = result; renderedRecipe = result == nil ? nil : edit
                    loadFailed = result == nil
                    if result == nil { message = "This preview could not be rendered. Choose another preset or reopen the editor." }
                    if before == nil { before = await Task.detached { ImageEditor.preview(source: source, recipe: .original) }.value }
                }
                .alert("Save recipe", isPresented: $showName) {
                    TextField("Recipe name", text: $name)
                    Button("Save") { do { try recipes.save(name: name, recipe: recipe) } catch { message = error.localizedDescription } }
                    Button("Cancel", role: .cancel) {}
                }
                .alert("Photo editor", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
        }.tint(Palette.yellow)
    }

    private struct PreviewKey: Hashable { let recipe: EditRecipe; let loaded: Bool }
    private func adjustment(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack {
            HStack { Text(title); Spacer(); Text(value.wrappedValue, format: .number.precision(.fractionLength(2))).foregroundStyle(.secondary) }
            Slider(value: value, in: range).tint(Palette.yellow)
        }
    }
    private func save() {
        saving = true
        let edit = recipe
        let url = library.url(for: photo)
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) { try ImageEditor.export(data: Data(contentsOf: url), recipe: edit) }.value
                let copy = try await library.add(data: data, mode: "Edited", isDemo: photo.isDemo, aspect: edit.crop?.rawValue ?? photo.aspect, subject: photo.subject)
                if let collection = photo.collection { library.setCollection(collection, for: copy) }
                dismiss()
            } catch { message = error.localizedDescription; saving = false }
        }
    }
}
