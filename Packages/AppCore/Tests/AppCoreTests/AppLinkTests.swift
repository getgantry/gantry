import Foundation
import Testing
@testable import AppCore

struct AppLinkTests {
    private func parse(_ string: String) -> AppLink? {
        AppLink.parse(URL(string: string)!)
    }

    @Test func opensGlobalPlaces() {
        #expect(parse("gantry://open/dashboard") == .open(target: "dashboard", host: nil, item: nil))
        #expect(parse("gantry://open/Kubernetes") == .open(target: "kubernetes", host: nil, item: nil))
        #expect(parse("gantry://open/usage") == .open(target: "usage", host: nil, item: nil))
        #expect(parse("gantry://open/usage")?.closesPalette == true)
    }

    @Test func opensHostSectionsWithHostAndItem() {
        #expect(parse("gantry://open/containers?host=Apple%20Container&item=web")
            == .open(target: "containers", host: "Apple Container", item: "web"))
        #expect(parse("gantry://open/files") == .open(target: "hostFiles", host: nil, item: nil))
        #expect(parse("gantry://open/clusters?host=&item=") == .open(target: "clusters", host: nil, item: nil))
        #expect(parse("gantry://open/Builds?host=Apple") == .open(target: "builds", host: "Apple", item: nil))
    }

    @Test func rejectsUnknownPlacesAndOtherSchemes() {
        #expect(parse("gantry://open/nowhere") == nil)
        #expect(parse("gantry://open") == nil)
        #expect(parse("https://open/containers") == nil)
        // Control links of the widget extension go to their own handler.
        #expect(parse("gantry://control?action=x") == nil)
    }

    @Test func parsesPaletteSettingsAndDebugCommands() {
        #expect(parse("gantry://palette") == .palette)
        #expect(parse("gantry://settings") == .settings)
        #expect(parse("gantry://debug/snapshot?path=/tmp/a.png") == .snapshot(path: "/tmp/a.png"))
        #expect(parse("gantry://debug/snapshot?path=relative.png") == nil)
        #expect(parse("gantry://debug/appearance?mode=dark") == .appearance("dark"))
        #expect(parse("gantry://debug/state?path=/tmp/s.json") == .state(path: "/tmp/s.json"))
        #expect(parse("gantry://debug/appearance?mode=blue") == nil)
        #expect(parse("gantry://debug/activity?path=/tmp/a.json") == .activity(path: "/tmp/a.json"))
        #expect(parse("gantry://debug/activity?path=a.json") == nil)
        #expect(parse("gantry://debug/menubar?path=/tmp/m.png") == .menuBarSnapshot(path: "/tmp/m.png"))
        #expect(parse("gantry://debug/pull?ref=alpine:3.20&host=Apple") == .debugPull(reference: "alpine:3.20", host: "Apple"))
        #expect(parse("gantry://debug/pull?ref=alpine") == .debugPull(reference: "alpine", host: nil))
        #expect(parse("gantry://debug/pull") == nil)
        #expect(parse("gantry://debug/cancel") == .cancelNewestOperation)
        #expect(parse("gantry://debug/cancel")?.closesPalette == false)
        #expect(parse("gantry://debug/compose?action=down&project=web&host=nettop")
            == .debugCompose(action: .down, project: "web", host: "nettop"))
        #expect(parse("gantry://debug/compose?action=pull&project=web") == .debugCompose(action: .pull, project: "web", host: nil))
        #expect(parse("gantry://debug/compose?action=up&project=web") == nil)
        #expect(parse("gantry://debug/compose?action=down") == nil)
        #expect(parse("gantry://debug/tab?name=Changes") == .containerTab("changes"))
        #expect(parse("gantry://debug/tab?name=changes")?.closesPalette == false)
        #expect(parse("gantry://debug/tab") == nil)
    }

    @Test func placesClosePaletteButPaletteAndDebugLinksKeepIt() {
        #expect(AppLink.open(target: "containers", host: nil, item: nil).closesPalette)
        #expect(AppLink.open(target: "dashboard", host: "Local", item: "web").closesPalette)
        #expect(AppLink.settings.closesPalette)
        #expect(!AppLink.palette.closesPalette)
        #expect(!AppLink.snapshot(path: "/tmp/a.png").closesPalette)
        #expect(!AppLink.state(path: "/tmp/s.json").closesPalette)
        #expect(!AppLink.appearance("dark").closesPalette)
        #expect(parse("gantry://open/containers")?.closesPalette == true)
        #expect(parse("gantry://debug/state?path=/tmp/s.json")?.closesPalette == false)
    }

    @Test func resolvesHostsByIDOrName() {
        let a = UUID(), b = UUID()
        let hosts = [(id: a, name: "Local"), (id: b, name: "Apple Container")]
        #expect(AppLink.resolveHost(nil, in: hosts) == a)
        #expect(AppLink.resolveHost("apple container", in: hosts) == b)
        #expect(AppLink.resolveHost(b.uuidString, in: hosts) == b)
        #expect(AppLink.resolveHost("missing", in: hosts) == nil)
    }
}
