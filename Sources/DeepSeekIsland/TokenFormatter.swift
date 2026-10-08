import Foundation

enum TokenFormatter {
    static func short(_ count: Int64) -> String {
        guard count >= 0 else { return "—" }
        if count >= 10_000_000 {
            return scaled(count, unit: 100_000_000, decimals: 2) + "亿"
        }
        if count >= 1_000_000 {
            return scaled(count, unit: 10_000, decimals: 0) + "万"
        }
        if count >= 100_000 {
            return scaled(count, unit: 10_000, decimals: 1) + "万"
        }
        if count >= 100 {
            return scaled(count, unit: 10_000, decimals: 2) + "万"
        }
        return count == 0 ? "0万" : "<0.01万"
    }

    private static func scaled(_ count: Int64, unit: Int64, decimals: Int) -> String {
        let factor = Int64([1, 10, 100][decimals])
        let scaled = count / (unit / factor)
        let whole = scaled / factor
        guard decimals > 0 else { return String(whole) }
        var fraction = String(format: "%0*d", decimals, Int(scaled % factor))
        while fraction.last == "0" { fraction.removeLast() }
        return fraction.isEmpty ? String(whole) : "\(whole).\(fraction)"
    }
}
