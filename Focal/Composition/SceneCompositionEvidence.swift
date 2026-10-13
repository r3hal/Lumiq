import Foundation

struct CompositionLine {
    var start: UnitPoint2D
    var end: UnitPoint2D
    var support: Double
    var length: Double { start.distance(to: end) }
    var diagonal: Bool {
        let dx = abs(end.x-start.x), dy = abs(end.y-start.y)
        return dx > 0.15 && dy > 0.15 && dy/dx > 0.25 && dy/dx < 4
    }
    func distance(to point: UnitPoint2D) -> Double {
        let dx = end.x-start.x, dy = end.y-start.y
        let denominator = dx*dx+dy*dy
        guard denominator > 0 else { return .infinity }
        let t = max(0,min(1,((point.x-start.x)*dx+(point.y-start.y)*dy)/denominator))
        return hypot(point.x-start.x-t*dx,point.y-start.y-t*dy)
    }
}

/// Bounded CPU analysis of actual visible pixels. No extra Vision inference,
/// depth claims, fabricated objects, or changes to native preview resolution.
struct SceneCompositionEvidence {
    struct Region {
        var edgeDensity = 0.0
        var variance = 0.0
        var clipping = 0.0
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var calm: Double { max(0,1-edgeDensity*4-sqrt(max(0,variance))*2) }
    }
    let image: SubjectImageEvidence
    let timestamp: TimeInterval
    var lines: [CompositionLine] = []
    var symmetry: Double = 0
    var repetition: Double = 0

    init?(image: SubjectImageEvidence, projection: PreviewProjection, timestamp: TimeInterval) {
        guard image.width > 2, image.height > 2, image.pixels.count == image.width*image.height,
              timestamp.isFinite, projection.imageAspect.isFinite, projection.previewAspect.isFinite,
              projection.imageAspect > 0, projection.previewAspect > 0,
              image.pixels.allSatisfy({ [$0.red,$0.green,$0.blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }) else { return nil }
        let width = 48, height = min(80,max(24,Int(Double(width)/projection.previewAspect)))
        var pixels = [SubjectImageEvidence.Pixel](); pixels.reserveCapacity(width*height)
        for y in 0..<height {
            for x in 0..<width {
                let point = projection.imagePoint(.init(x:(Double(x)+0.5)/Double(width),y:(Double(y)+0.5)/Double(height)))
                let sx = min(image.width-1,max(0,Int(point.x*Double(image.width))))
                let sy = min(image.height-1,max(0,Int(point.y*Double(image.height))))
                pixels.append(image.pixels[sy*image.width+sx])
            }
        }
        self.image = SubjectImageEvidence(pixels:pixels,width:width,height:height)
        self.timestamp = timestamp
        let whole = region(Self.full)
        if whole.variance > 0.008 {
            var difference = 0.0, pairs = 0.0
            for y in 0..<height {
                for x in 0..<width/2 {
                    let a = pixels[y*width+x], b = pixels[y*width+width-1-x]
                    difference += (abs(a.red-b.red)+abs(a.green-b.green)+abs(a.blue-b.blue))/3; pairs += 1
                }
            }
            symmetry = max(0,1-(difference/max(1,pairs))/max(0.08,sqrt(whole.variance)))
            repetition = periodicity()
        }
        lines = longLines()
    }

    static let full = CGRect(x:0,y:0,width:1,height:1)
    func isFresh(at timestamp: TimeInterval) -> Bool { timestamp.isFinite && timestamp >= self.timestamp && timestamp-self.timestamp <= 1.25 }
    func region(_ rect: CGRect, excluding subject: CGRect? = nil) -> Region {
        let clipped = rect.intersection(Self.full)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return Region() }
        var result = Region(), n = 0.0, sum = 0.0, squares = 0.0
        for y in 1..<image.height {
            for x in 1..<image.width {
                let point = CGPoint(x:(Double(x)+0.5)/Double(image.width),y:(Double(y)+0.5)/Double(image.height))
                guard clipped.contains(point), subject?.contains(point) != true else { continue }
                let p = image.pixels[y*image.width+x], value = p.luma
                let gradient = abs(value-image.pixels[y*image.width+x-1].luma)+abs(value-image.pixels[(y-1)*image.width+x].luma)
                n += 1; sum += value; squares += value*value
                result.red += p.red; result.green += p.green; result.blue += p.blue
                if gradient > 0.15 { result.edgeDensity += 1 }
                if value < 0.035 || value > 0.97 { result.clipping += 1 }
            }
        }
        guard n >= 4 else { return Region(edgeDensity:1,variance:1,clipping:1) }
        result.edgeDensity /= n; result.clipping /= n
        result.red /= n; result.green /= n; result.blue /= n
        result.variance = max(0,squares/n-pow(sum/n,2))
        return result
    }
    func separation(subject: CGRect) -> Double {
        let inside = region(subject), outside = region(subject.insetBy(dx:-0.15,dy:-0.15),excluding:subject)
        return min(1,sqrt(pow(inside.red-outside.red,2)+pow(inside.green-outside.green,2)+pow(inside.blue-outside.blue,2))/0.7)
    }
    func horizontalBoundary() -> CompositionLine? {
        lines.filter { abs($0.end.y-$0.start.y) < 0.045 && abs($0.end.x-$0.start.x) > 0.65 && $0.start.y > 0.15 && $0.start.y < 0.85 }
            .max { $0.support < $1.support }
    }
    private func periodicity() -> Double {
        // Compare repeating bands against their actual variance; white walls
        // and dense random noise cannot qualify just because they have edges.
        var best = 0.0
        for horizontal in [true,false] {
            let count = horizontal ? image.width : image.height
            var means = [Double](repeating:0,count:count)
            for y in 0..<image.height {
                for x in 0..<image.width { means[horizontal ? x : y] += image.pixels[y*image.width+x].luma/Double(horizontal ? image.height : image.width) }
            }
            let mean = means.reduce(0,+)/Double(count)
            let variance = means.reduce(0) { $0+pow($1-mean,2) }/Double(count)
            guard variance > 0.006 else { continue }
            for lag in 4...max(4,count/3) {
                var error = 0.0
                for i in lag..<count { error += pow(means[i]-means[i-lag],2) }
                let similarity = 1-error/Double(count-lag)/(2*variance)
                // Must differ midway through the period, not a monotone gradient.
                var halfway = 0.0
                for i in lag..<count { halfway += pow(means[i]-means[i-lag/2],2) }
                if halfway/Double(count-lag) > variance { best = max(best,similarity) }
            }
        }
        return max(0,min(1,best))
    }
    private func longLines() -> [CompositionLine] {
        var edges = [UnitPoint2D]()
        for y in 1..<image.height-1 {
            for x in 1..<image.width-1 {
                let dx = image.pixels[y*image.width+x+1].luma-image.pixels[y*image.width+x-1].luma
                let dy = image.pixels[(y+1)*image.width+x].luma-image.pixels[(y-1)*image.width+x].luma
                if hypot(dx,dy) > 0.22 { edges.append(.init(x:Double(x)/Double(image.width),y:Double(y)/Double(image.height))) }
            }
        }
        // Subsample before voting. At most ~21k votes per admitted evidence sample.
        let stride = max(1,(edges.count+599)/600)
        let sampled = edges.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
        guard sampled.count >= 12 else { return [] }
        var result = [CompositionLine]()
        for angle in 0..<18 {
            let theta = Double(angle)*Double.pi/18, nx = cos(theta), ny = sin(theta)
            var buckets = [[UnitPoint2D]](repeating:[],count:145)
            for p in sampled {
                let bin = min(144,max(0,Int(((p.x*nx+p.y*ny)+1.5)*48)))
                buckets[bin].append(p)
            }
            for points in buckets where points.count >= 10 {
                let sorted = points.sorted { -$0.x*ny+$0.y*nx < -$1.x*ny+$1.y*nx }
                guard let start = sorted.first, let end = sorted.last, start.distance(to:end) >= 0.4 else { continue }
                var occupied = Set<Int>()
                let length = start.distance(to:end)
                for p in points { occupied.insert(min(15,Int(p.distance(to:start)/length*16))) }
                let support = Double(occupied.count)/16
                guard support >= 0.75 else { continue }
                let line = CompositionLine(start:start,end:end,support:support)
                if !result.contains(where:{ $0.distance(to:start) < 0.04 && $0.distance(to:end) < 0.04 }) { result.append(line) }
            }
        }
        return Array(result.sorted { $0.length*$0.support > $1.length*$1.support }.prefix(8))
    }
}
