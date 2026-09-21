import XCTest
@testable import FITHealthCore

final class OpenMeteoTests: XCTestCase {
    func testRoutingAndUTCDateBoundary() throws {
        let date = Date(timeIntervalSince1970: 86400 - 600)
        let recent = OpenMeteo.url(date: date, latitude: 30, longitude: 110, now: date)
        XCTAssertEqual(recent.host, "api.open-meteo.com")
        let items = URLComponents(url: recent, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "start_date" }?.value, "1970-01-01")
        XCTAssertEqual(items.first { $0.name == "end_date" }?.value, "1970-01-02")
        XCTAssertFalse(items.contains { $0.name == "apikey" })
        XCTAssertEqual(OpenMeteo.url(date: date, latitude: 30, longitude: 110,
                                   now: date.addingTimeInterval(8 * 86400)).host, "archive-api.open-meteo.com")
    }

    func testNearestHourUnitsAndPartialValues() throws {
        let data = Data(#"{"hourly":{"time":[0,3600],"temperature_2m":[20,25],"relative_humidity_2m":[50,71],"weather_code":[0,2],"surface_pressure":[1000,1006]}}"#.utf8)
        let value = try OpenMeteo.sample(data: data, at: Date(timeIntervalSince1970: 3000))
        XCTAssertEqual(value, OpenMeteo.Sample(temperature: 25, humidity: 0.71, code: 2, pressure: 1006))
        XCTAssertEqual(OpenMeteo.conditionName(2), "Partly Cloudy")
        XCTAssertThrowsError(try OpenMeteo.sample(data: data, at: Date(timeIntervalSince1970: 9000)))
        let partial = Data(#"{"hourly":{"time":[0],"temperature_2m":[24],"relative_humidity_2m":[101],"weather_code":[999],"surface_pressure":[null]}}"#.utf8)
        XCTAssertEqual(try OpenMeteo.sample(data: partial, at: Date(timeIntervalSince1970: 0)),
                       OpenMeteo.Sample(temperature: 24, humidity: nil, code: nil, pressure: nil))
    }

    func testEmptyNullAndShortArrays() {
        for json in [#"{"hourly":{"time":[]}}"#, #"{"hourly":{"time":[0],"temperature_2m":[null]}}"#,
                     #"{"hourly":{"time":[0],"temperature_2m":[]}}"#] {
            XCTAssertThrowsError(try OpenMeteo.sample(data: Data(json.utf8), at: Date(timeIntervalSince1970: 0)))
        }
    }
}
