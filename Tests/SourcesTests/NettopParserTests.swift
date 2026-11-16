import Testing
@testable import Sources
import SignalBus

@Suite struct NettopParserTests {
    @Test func skipsTotalsBlockAndSumsHelpersByName() {
        // Pids name their app: two Brave helpers, and two versions of a CLI.
        let apps: [Int32: String] = [10275: "Brave Browser", 10276: "Brave Browser", 32467: "claude", 32468: "claude"]
        var p = NettopParser { name, pid in apps[pid] ?? name }
        let lines = [
            ",bytes_in,bytes_out,",
            "Safari.100,999999,999999,",          // totals since boot: ignored
            ",bytes_in,bytes_out,",
            "Brave Browser H.10275,100,50,",
            "Brave Browser H.10276,10,0,",
            "2.1.322.32467,5,5,",                  // name containing dots
            "2.1.323.32468,1,1,",
            "idle.1,0,0,",
            ",bytes_in,bytes_out,",
        ]
        var snapshots: [NettopParser.Snapshot] = []
        for l in lines { if let s = p.feed(line: l + "\r") { snapshots.append(s) } }
        #expect(snapshots.count == 1)
        #expect(snapshots[0].bytesByApp == ["Brave Browser": 160, "claude": 12])
        #expect(snapshots[0].total == 172)
    }
}

@Suite struct AppNameTests {
    @Test func namesTheAppAProcessBelongsTo() {
        #expect(AppName.fromPath("/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/131.1.73.97/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)") == "Brave Browser")
        #expect(AppName.fromPath("/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)") == "Visual Studio Code")
        #expect(AppName.fromPath("/Applications/Syncthing.app/Contents/Resources/syncthing/syncthing") == "Syncthing")
        #expect(AppName.fromPath("/Applications/Xcode.app/Contents/Developer/usr/bin/git") == "git")
        #expect(AppName.fromPath("/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking") == "com.apple.WebKit.Networking")
        #expect(AppName.fromPath("/Users/me/.local/share/claude/versions/2.1.322") == "claude")
        #expect(AppName.fromPath("/usr/sbin/mDNSResponder") == "mDNSResponder")
        #expect(AppName.fromPath("/Library/Application Support/Adobe/Adobe Desktop Common/Core/Creative Cloud Helper.app/Contents/MacOS/Creative Cloud Helper") == "Creative Cloud")
        #expect(AppName.fromPath("/System/Library/PrivateFrameworks/IDS.framework/identityservicesd.app/Contents/MacOS/identityservicesd") == "identityservicesd")
    }

    @Test func tidiesTruncatedHelperNames() {
        #expect(AppName.tidy("Brave Browser H") == "Brave Browser")
        #expect(AppName.tidy("Code Helper (Pl") == "Code")
        #expect(AppName.tidy("Spotify Helper") == "Spotify")
        #expect(AppName.tidy("Google Drive") == "Google Drive")
        #expect(AppName.tidy("Autodesk Identi") == "Autodesk Identi")
    }

    @Test func oldTruncatedNamesStillMatch() {
        #expect(AppName.same("identityservice", "identityservicesd"))
        #expect(AppName.same("Brave Browser H", "Brave Browser"))
        #expect(AppName.same("rapportd", "rapportd"))
        #expect(!AppName.same("Spotify", "Spotify Connect"))
        #expect(["mDNSResponder", "identityservice"].containsApp("identityservicesd"))
    }
}
