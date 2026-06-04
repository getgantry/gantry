import Foundation
import Testing
@testable import DockerKit

// MARK: - ls -l line parser

@Test func parsesBusyboxDirectoryLine() {
    // Busybox right-pads columns with multiple spaces.
    let line = "drwxr-xr-x    2 root     root          4096 Jun  3 10:15 etc"
    let entry = try? #require(DockerClient.parseLSLine(line))
    #expect(entry?.name == "etc")
    #expect(entry?.isDirectory == true)
    #expect(entry?.isSymlink == false)
    #expect(entry?.size == 4096)
    #expect(entry?.modified != nil)
}

@Test func parsesCoreutilsDirectoryLine() {
    // GNU coreutils uses single-space separation.
    let line = "drwxr-xr-x 2 root root 4096 Jun  3 10:15 etc"
    let entry = try? #require(DockerClient.parseLSLine(line))
    #expect(entry?.name == "etc")
    #expect(entry?.isDirectory == true)
    #expect(entry?.size == 4096)
}

@Test func parsesRegularFileLine() {
    let line = "-rw-r--r-- 1 root root 1234 Jun  3 10:15 hosts"
    let entry = try? #require(DockerClient.parseLSLine(line))
    #expect(entry?.name == "hosts")
    #expect(entry?.isDirectory == false)
    #expect(entry?.isSymlink == false)
    #expect(entry?.size == 1234)
}

@Test func parsesNameWithSpaces() {
    let line = "-rw-r--r-- 1 root root 10 Jun  3 10:15 my file name.txt"
    let entry = try? #require(DockerClient.parseLSLine(line))
    #expect(entry?.name == "my file name.txt")
    #expect(entry?.size == 10)
}

@Test func parsesSymlinkLineStrippingTarget() {
    let line = "lrwxrwxrwx 1 root root 7 Jun  3 10:15 sh -> busybox"
    let entry = try? #require(DockerClient.parseLSLine(line))
    #expect(entry?.name == "sh")
    #expect(entry?.isSymlink == true)
    #expect(entry?.isDirectory == false)
}

@Test func parsesSymlinkWithSpacesInNameAndTarget() {
    let line = "lrwxrwxrwx 1 root root 12 Jun  3 10:15 my link -> some target"
    let entry = try? #require(DockerClient.parseLSLine(line))
    #expect(entry?.name == "my link")
    #expect(entry?.isSymlink == true)
}

@Test func skipsTotalLine() {
    #expect(DockerClient.parseLSLine("total 12") == nil)
    #expect(DockerClient.parseLSLine("total 0") == nil)
}

@Test func skipsBlankLine() {
    #expect(DockerClient.parseLSLine("") == nil)
    #expect(DockerClient.parseLSLine("   ") == nil)
}

@Test func parsesYearFormDate() {
    // Older files show a year instead of HH:mm.
    let line = "-rw-r--r-- 1 root root 88 Jan 15 2023 old.conf"
    let entry = try? #require(DockerClient.parseLSLine(line))
    #expect(entry?.name == "old.conf")
    #expect(entry?.size == 88)
    let date = try? #require(entry?.modified)
    let year = Calendar(identifier: .gregorian).component(.year, from: date ?? Date())
    #expect(year == 2023)
}

@Test func parsesTimeFormUsesCurrentYear() {
    let line = "-rw-r--r-- 1 root root 88 Jun  3 10:15 recent.conf"
    let entry = try? #require(DockerClient.parseLSLine(line))
    let date = try? #require(entry?.modified)
    let thisYear = Calendar(identifier: .gregorian).component(.year, from: Date())
    let year = Calendar(identifier: .gregorian).component(.year, from: date ?? Date())
    #expect(year == thisYear)
}

@Test func parsesCharacterDeviceAsFile() {
    let line = "crw-rw-rw- 1 root root 1, 3 Jun  3 10:15 null"
    // Device lines have a "major, minor" pair instead of a size; the parser is
    // tolerant: it still extracts a name and treats it as a non-dir entry.
    let entry = DockerClient.parseLSLine(line)
    #expect(entry?.isDirectory == false)
    #expect(entry?.isSymlink == false)
}

@Test func ignoresNonListingLines() {
    #expect(DockerClient.parseLSLine("ls: cannot access '/nope': No such file or directory") == nil)
}

// MARK: - Whole-output parsing

@Test func parsesFullBusyboxListing() {
    let output = """
    total 16
    drwxr-xr-x    2 root     root          4096 Jun  3 10:15 etc
    -rw-r--r--    1 root     root            42 Jun  3 10:15 index.html
    lrwxrwxrwx    1 root     root             7 Jun  3 10:15 sh -> busybox
    """
    let entries = DockerClient.parseLSOutput(output)
    #expect(entries.count == 3)
    let names = Set(entries.map(\.name))
    #expect(names == ["etc", "index.html", "sh"])
    #expect(entries.first { $0.name == "etc" }?.isDirectory == true)
    #expect(entries.first { $0.name == "sh" }?.isSymlink == true)
}

@Test func parsesFullCoreutilsListing() {
    let output = """
    total 16
    drwxr-xr-x 2 root root 4096 Jun  3 10:15 conf.d
    -rw-r--r-- 1 root root 1024 Jan 15 2023 nginx.conf
    drwxr-xr-x 2 root root 4096 Jun  3 10:15 a directory with spaces
    """
    let entries = DockerClient.parseLSOutput(output)
    #expect(entries.count == 3)
    let names = Set(entries.map(\.name))
    #expect(names == ["conf.d", "nginx.conf", "a directory with spaces"])
}
