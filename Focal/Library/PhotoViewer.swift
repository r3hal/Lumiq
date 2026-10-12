import SwiftUI

struct PhotoViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image { ZoomImage(image: image).ignoresSafeArea() }
            else if failed { ContentUnavailableView("Photo unavailable", systemImage: "photo.badge.exclamationmark") }
            else { ProgressView().tint(.white).frame(maxWidth: .infinity,maxHeight: .infinity) }
            Button { dismiss() } label: { Image(systemName: "xmark").padding(15).background(.black.opacity(0.6),in: Circle()) }.padding()
        }.foregroundStyle(.white)
            .task {
                let loaded = await PhotoLoader.load(url: url,maxPixels: 6000)
                guard !Task.isCancelled else { return }
                image = loaded; failed = loaded == nil
            }
    }
}

private struct ZoomImage: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = ImageScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        scroll.backgroundColor = .black
        scroll.imageView.image = image
        scroll.imageView.contentMode = .scaleAspectFit
        scroll.addSubview(scroll.imageView)
        context.coordinator.imageView = scroll.imageView
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2; scroll.addGestureRecognizer(tap)
        return scroll
    }
    func updateUIView(_ uiView: UIScrollView,context: Context) {}
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scroll = recognizer.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 { scroll.setZoomScale(1,animated: true) }
            else {
                let point = recognizer.location(in: imageView)
                scroll.zoom(to: CGRect(x: point.x - scroll.bounds.width/6,y: point.y - scroll.bounds.height/6,width: scroll.bounds.width/3,height: scroll.bounds.height/3),animated: true)
            }
        }
    }
    final class ImageScrollView: UIScrollView {
        let imageView = UIImageView()
        private var previousSize = CGSize.zero
        override func layoutSubviews() {
            super.layoutSubviews()
            if previousSize != bounds.size {
                setZoomScale(1,animated: false)
                imageView.frame = CGRect(origin: .zero,size: bounds.size)
                contentSize = bounds.size
                previousSize = bounds.size
            }
        }
    }
}
