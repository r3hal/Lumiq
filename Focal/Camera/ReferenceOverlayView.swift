import SwiftUI
import PhotosUI
import ImageIO

struct ReferenceOverlayView: View {
    @Binding var image: UIImage?
    @Binding var opacity: Double
    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    PhotosPicker(selection: $selection,matching: .images) { Label("Choose reference photo",systemImage: "photo.badge.plus") }.buttonStyle(.borderedProminent)
                    if loading { ProgressView("Importing reference…") }
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 360)
                        HStack { Text("Overlay opacity"); Spacer(); Text(opacity,format: .percent.precision(.fractionLength(0))) }
                        Slider(value: $opacity,in: 0.05...0.9).tint(Palette.yellow)
                        Button("Remove reference",role: .destructive) { self.image = nil; selection = nil }
                    }
                    Text("The reference is imported locally and resized for display. It fills the selected camera frame; edges may crop. It never appears in the saved photo.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red) }
                }.padding(24)
            }.background(Palette.ink).navigationTitle("Reference overlay").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
                .task(id: selection) {
                    guard let selection else { loading = false; return }
                    loading = true; error = nil
                    do {
                        guard let data = try await selection.loadTransferable(type: Data.self) else { throw PhotoRenderer.RenderError.invalidImage }
                        let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                            guard let source = CGImageSourceCreateWithData(data as CFData,nil), let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:2000] as CFDictionary) else { return nil }
                            return UIImage(cgImage:cg)
                        }.value
                        guard !Task.isCancelled else { return }
                        guard let loaded else { throw PhotoRenderer.RenderError.invalidImage }
                        image = loaded
                    } catch {
                        guard !Task.isCancelled else { return }
                        self.error = error.localizedDescription
                    }
                    loading = false
                }
        }.tint(Palette.yellow)
    }
}
