import Foundation

/// Robertson isotemperature-line interpolation in CIE 1960 UCS.
/// Numerical table: Wyszecki & Stiles, Color Science, table 1(3.11), as
/// published at https://colour.readthedocs.io/en/latest/_modules/colour/temperature/robertson1968.html
enum CorrelatedColorTemperature {
    private static let lines: [(r: Double, u: Double, v: Double, slope: Double)] = [
        (0,0.18006,0.26352,-0.24341),(10,0.18066,0.26589,-0.25479),
        (20,0.18133,0.26846,-0.26876),(30,0.18208,0.27119,-0.28539),
        (40,0.18293,0.27407,-0.30470),(50,0.18388,0.27709,-0.32675),
        (60,0.18494,0.28021,-0.35156),(70,0.18611,0.28342,-0.37915),
        (80,0.18740,0.28668,-0.40955),(90,0.18880,0.28997,-0.44278),
        (100,0.19032,0.29326,-0.47888),(125,0.19462,0.30141,-0.58204),
        (150,0.19962,0.30921,-0.70471),(175,0.20525,0.31647,-0.84901),
        (200,0.21142,0.32312,-1.0182),(225,0.21807,0.32909,-1.2168),
        (250,0.22511,0.33439,-1.4512),(275,0.23247,0.33904,-1.7298),
        (300,0.24010,0.34308,-2.0637),(325,0.24792,0.34655,-2.4681),
        (350,0.25591,0.34951,-2.9641),(375,0.26400,0.35200,-3.5814),
        (400,0.27218,0.35407,-4.3633),(425,0.28039,0.35577,-5.3762),
        (450,0.28863,0.35714,-6.7262),(475,0.29685,0.35823,-8.5955),
        (500,0.30505,0.35907,-11.324),(525,0.31320,0.35968,-15.628),
        (550,0.32129,0.36011,-23.325),(575,0.32931,0.36038,-40.770),
        (600,0.33724,0.36051,-116.45)
    ]

    static func kelvin(x: Double, y: Double) -> Double? {
        guard x.isFinite, y.isFinite, x > 0, y > 0, x + y < 1 else { return nil }
        let denominator = -2 * x + 12 * y + 3
        let u = 4 * x / denominator, v = 6 * y / denominator
        func distance(_ line: (r: Double, u: Double, v: Double, slope: Double)) -> Double {
            (v - line.v - line.slope * (u - line.u)) / sqrt(1 + line.slope * line.slope)
        }
        var previous = lines[0]
        var previousDistance = distance(previous)
        for line in lines.dropFirst() {
            let currentDistance = distance(line)
            if previousDistance >= 0, currentDistance <= 0 {
                let fraction = previousDistance / (previousDistance - currentDistance)
                let reciprocal = previous.r + fraction * (line.r - previous.r)
                let locusU = previous.u + fraction * (line.u - previous.u)
                let locusV = previous.v + fraction * (line.v - previous.v)
                guard reciprocal > 0, hypot(u - locusU, v - locusV) <= 0.05 else { return nil }
                return 1_000_000 / reciprocal
            }
            previous = line
            previousDistance = currentDistance
        }
        return nil
    }
}
