import SwiftUI

struct PhotoDetailView: View {
    let photo: SavedPhoto
    @EnvironmentObject private var library: PhotoLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var exporting = false
    @State private var message: String?
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var variant = "Photo"
    private var current: SavedPhoto { library.photos.first { $0.id == photo.id } ?? photo }
    private var imageURL: URL {
        if variant == "Scan", let scan = library.scanURL(for: photo) { return scan }
        if variant == "Original", let original = library.originalURL(for: photo) { return original }
        return library.url(for: photo)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if photo.scanFilename != nil || photo.originalFilename != nil {
                        Picker("Image", selection: $variant) {
                            Text("Photo").tag("Photo")
                            if photo.scanFilename != nil { Text("Scan").tag("Scan") }
                            if photo.originalFilename != nil { Text("Original").tag("Original") }
                        }.pickerStyle(.segmented)
                    }
                    PhotoImage(url: imageURL, maxPixels: 4096)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .accessibilityLabel(photo.isDemo ? "Sample lake and mountain scene" : "Your captured photo")
                    HStack {
                        VStack(alignment: .leading, spacing: 7) {
                            Eyebrow(text: photo.isDemo ? "Demo frame" : "A moment, kept").foregroundStyle(Palette.mint)
                            Text(photo.createdAt, format: .dateTime.month(.wide).day().year())
                                .font(.system(.title2, design: .serif))
                            Text("\(photo.mode) composition · \(photo.createdAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let resolution = photo.resolutionLabel {
                                Text(resolution).font(.system(.caption2, design: .monospaced)).foregroundStyle(Palette.mint)
                            }
                            if let aspect = photo.aspect { Text("Aspect \(aspect)").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button { library.toggleFavorite(current) } label: {
                            Image(systemName: current.isFavorite ? "heart.fill" : "heart")
                                .font(.title2).foregroundStyle(Palette.mint).frame(width: 48, height: 48)
                        }
                        .accessibilityLabel(current.isFavorite ? "Remove from favorites" : "Add to favorites")
                    }
                    Button {
                        exporting = true
                        Task {
                            do { try await library.saveToPhotos(photo, imageURL: imageURL); message = "Saved to your iPhone photo library." }
                            catch { message = error.localizedDescription }
                            exporting = false
                        }
                    } label: {
                        HStack {
                            if exporting { ProgressView().tint(Palette.ink) }
                            else { Image(systemName: "square.and.arrow.down") }
                            Text(exporting ? "Saving…" : "Save to Photos")
                        }
                    }
                    .buttonStyle(PrimaryButton()).disabled(exporting)
                    if let raw = library.rawURL(for: photo) {
                        Button {
                            shareItems = [raw]
                            showShare = true
                        } label: { Label("Share RAW original", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(12) }
                        .foregroundStyle(Palette.yellow)
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete from Focal", systemImage: "trash").font(.subheadline).frame(maxWidth: .infinity).padding(12)
                    }
                }
                .padding(22)
            }
            .background(Palette.ink)
            .navigationTitle("Your frame")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        shareItems = [imageURL]
                        showShare = true
                    } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share photo")
                }
            }
            .confirmationDialog("Delete this photo from Focal?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete photo", role: .destructive) {
                    do { try library.delete(photo); dismiss() }
                    catch { message = error.localizedDescription }
                }
            } message: { Text("Copies saved to Photos or shared elsewhere will remain.") }
            .alert("Your frame", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
            .sheet(isPresented: $showShare) {
                ActivitySheet(items: shareItems)
            }
        }
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
