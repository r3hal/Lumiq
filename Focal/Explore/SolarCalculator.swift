import Foundation

struct SolarCalculator {
    /// Approximate NOAA solar geometry, without atmospheric refraction or a weather forecast.
    static func elevation(at date: Date, latitude: Double, longitude: Double) -> Double? {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = utc.ordinality(of: .day,in: .year,for: date) ?? 1
        let hours = Double(utc.component(.hour,from: date)) + Double(utc.component(.minute,from: date))/60 + Double(utc.component(.second,from: date))/3600
        let yearLength = Double(utc.range(of: .day,in: .year,for: date)?.count ?? 365)
        let gamma = 2 * Double.pi / yearLength * (Double(day-1)+(hours-12)/24)
        let annualEquation = 0.001868*cos(gamma)-0.032077*sin(gamma)
        let semiannualEquation = -0.014615*cos(2*gamma)-0.040849*sin(2*gamma)
        let equation = 229.18 * (0.000075+annualEquation+semiannualEquation)
        let annualDeclination = -0.399912*cos(gamma)+0.070257*sin(gamma)
        let semiannualDeclination = -0.006758*cos(2*gamma)+0.000907*sin(2*gamma)
        let thirdDeclination = -0.002697*cos(3*gamma)+0.00148*sin(3*gamma)
        let declination = 0.006918+annualDeclination+semiannualDeclination+thirdDeclination
        var minutes = (hours*60+equation+4*longitude).truncatingRemainder(dividingBy: 1440)
        if minutes < 0 { minutes += 1440 }
        let hourAngle = (minutes/4-180) * .pi/180
        let lat = latitude * .pi/180
        let cosZenith = max(-1,min(1,sin(lat)*sin(declination)+cos(lat)*cos(declination)*cos(hourAngle)))
        return 90-acos(cosZenith)*180 / .pi
    }
    static func goldenWindows(on date: Date, latitude: Double, longitude: Double, calendar: Calendar = .current) -> [DateInterval] {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day,value: 1,to: start) else { return [] }
        var intervals = [DateInterval](), beginning: Date?
        var time = start
        while time < end {
            let golden = elevation(at: time,latitude: latitude,longitude: longitude).map { (-4...6).contains($0) } ?? false
            if golden && beginning == nil { beginning = time }
            if !golden, let beginningValue = beginning { intervals.append(DateInterval(start: beginningValue,end: time)); beginning = nil }
            time = time.addingTimeInterval(60)
        }
        if let beginning { intervals.append(DateInterval(start: beginning,end: end)) }
        return intervals
    }
}
