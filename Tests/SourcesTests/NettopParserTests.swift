import Testing
@testable import Sources

@Suite struct NettopParserTests {
    @Test func skipsTotalsBlockAndSumsHelpersByName() {
        var p = NettopParser()
        let lines = [
            ",bytes_in,bytes_out,",
            "Safari.100,999999,999999,",          // totals since boot: ignored
            ",bytes_in,bytes_out,",
            "Brave Browser H.10275,100,50,",
            "Brave Browser H.10276,10,0,",
            "2.1.322.32467,5,5,",                  // name containing dots
            "idle.1,0,0,",
            ",bytes_in,bytes_out,",
        ]
        var snapshots: [NettopParser.Snapshot] = []
        for l in lines { if let s = p.feed(line: l + "\r") { snapshots.append(s) } }
        #expect(snapshots.count == 1)
        #expect(snapshots[0].bytesByApp == ["Brave Browser H": 160, "2.1.322": 10])
        #expect(snapshots[0].total == 170)
    }
}
