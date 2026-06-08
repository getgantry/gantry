import Foundation

/// Translates `container` CLI JSON (apple/container) into the Docker Engine
/// API shapes the rest of the app already decodes.
///
/// All functions are pure: they take the CLI's JSON bytes and return Docker
/// API JSON bytes, so the whole layer is unit-testable without spawning the
/// CLI. Input parsing is tolerant — apple/container's JSON schema is not
/// versioned, so unknown/missing fields degrade to defaults instead of
/// failing the whole list.
enum AppleContainerJSON {
    /// Seconds between the Unix epoch and Foundation's reference date —
    /// apple/container serializes dates as `timeIntervalSinceReferenceDate`.
    static let appleEpochOffset: Double = 978_307_200

    // MARK: - Generic helpers

    static func object(_ any: Any?) -> [String: Any] {
        any as? [String: Any] ?? [:]
    }

    static func array(_ any: Any?) -> [[String: Any]] {
        (any as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    static func string(_ any: Any?) -> String {
        any as? String ?? ""
    }

    static func int64(_ any: Any?) -> Int64 {
        switch any {
        case let value as Int64: value
        case let value as Int: Int64(value)
        case let value as Double: Int64(value)
        case let value as NSNumber: value.int64Value
        default: 0
        }
    }

    static func double(_ any: Any?) -> Double? {
        switch any {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        default: nil
        }
    }

    /// Converts an apple/container date (seconds since 2001-01-01) to Unix seconds.
    static func unixSeconds(fromAppleDate value: Any?) -> Int64 {
        guard let seconds = double(value) else { return 0 }
        return Int64(seconds + appleEpochOffset)
    }

    /// Converts an apple/container date to an RFC 3339 string ("" when absent).
    static func iso8601(fromAppleDate value: Any?) -> String {
        guard let seconds = double(value) else { return "" }
        let date = Date(timeIntervalSinceReferenceDate: seconds)
        return isoFormatter.string(from: date)
    }

    // ISO8601DateFormatter is documented thread-safe.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func encode(_ json: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    static func decode(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - State mapping

    /// apple/container reports "running" / "stopped" (plus transitional
    /// states); Docker's enum is richer. Anything stopped-like maps to
    /// `exited` so the existing UI state machinery applies unchanged.
    static func dockerState(fromAppleStatus status: String) -> String {
        switch status.lowercased() {
        case "running": "running"
        case "stopped", "exited": "exited"
        case "created": "created"
        case "paused": "paused"
        case "stopping": "removing"
        default: "exited"
        }
    }

    static func dockerStatusText(forDockerState state: String) -> String {
        switch state {
        case "running": "Up"
        case "created": "Created"
        default: "Exited"
        }
    }

    // MARK: - Localized byte counts

    /// Parses the CLI's human-formatted sizes ("4,2 MB", "4.2 MB", "634 KB").
    /// The CLI renders them with `ByteCountFormatter` in the *user's* locale,
    /// so both decimal separators (and locale-specific spaces) must parse.
    static func bytes(fromLocalizedSize text: String) -> Int64 {
        let cleaned = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return 0 }

        // Split the leading number from the trailing unit.
        var numberPart = ""
        var unitPart = ""
        for char in cleaned {
            if char.isNumber || char == "." || char == "," {
                if unitPart.isEmpty { numberPart.append(char) } else { return 0 }
            } else if char == " " {
                continue
            } else {
                unitPart.append(char)
            }
        }
        guard let value = Double(numberPart.replacingOccurrences(of: ",", with: ".")) else {
            return 0
        }

        let multiplier: Double
        switch unitPart.uppercased() {
        case "B", "BYTES", "БАЙТ": multiplier = 1
        case "KB", "КБ": multiplier = 1_000
        case "MB", "МБ": multiplier = 1_000_000
        case "GB", "ГБ": multiplier = 1_000_000_000
        case "TB", "ТБ": multiplier = 1_000_000_000_000
        case "PB", "ПБ": multiplier = 1_000_000_000_000_000
        case "KIB": multiplier = 1_024
        case "MIB": multiplier = 1_048_576
        case "GIB": multiplier = 1_073_741_824
        case "TIB": multiplier = 1_099_511_627_776
        case "": multiplier = 1
        default: return 0
        }
        return Int64(value * multiplier)
    }

    // MARK: - Containers

    /// `container list --format json` → `GET /containers/json` body.
    /// `all: false` keeps only running containers (the CLI is always asked
    /// with `--all` so one code path serves both).
    static func containersListBody(fromAppleList data: Data, all: Bool) throws -> Data {
        let apple = array(try decode(data))
        var rows: [[String: Any]] = []
        for element in apple {
            let row = containerSummaryJSON(fromAppleContainer: element)
            if !all, string(row["State"]) != "running" { continue }
            rows.append(row)
        }
        return try encode(rows)
    }

    /// One element of the CLI list → one `/containers/json` row.
    static func containerSummaryJSON(fromAppleContainer element: [String: Any]) -> [String: Any] {
        let config = object(element["configuration"])
        let id = string(config["id"])
        let state = dockerState(fromAppleStatus: string(element["status"]))
        let initProcess = object(config["initProcess"])
        let command = ([string(initProcess["executable"])]
            + ((initProcess["arguments"] as? [String]) ?? []))
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let image = object(config["image"])
        let descriptor = object(image["descriptor"])

        var ports: [[String: Any]] = []
        for port in array(config["publishedPorts"]) {
            var row: [String: Any] = [
                "PrivatePort": int64(port["containerPort"]),
                "Type": string(port["proto"]).isEmpty ? "tcp" : string(port["proto"])
            ]
            let host = int64(port["hostPort"])
            if host > 0 { row["PublicPort"] = host }
            let address = string(port["hostAddress"])
            if !address.isEmpty { row["IP"] = address }
            ports.append(row)
        }

        var mounts: [[String: Any]] = []
        for mount in array(config["mounts"]) {
            mounts.append(mountJSON(fromAppleMount: mount))
        }

        return [
            "Id": id,
            "Names": ["/" + id],
            "Image": string(image["reference"]),
            "ImageID": string(descriptor["digest"]),
            "Command": command,
            "Created": unixSeconds(fromAppleDate: element["startedDate"]),
            "Ports": ports,
            "Labels": (config["labels"] as? [String: String]) ?? [:],
            "State": state,
            "Status": dockerStatusText(forDockerState: state),
            "Mounts": mounts
        ]
    }

    /// Tolerant mount mapping: apple/container spells the fields differently
    /// across mount types, so several key candidates are tried.
    static func mountJSON(fromAppleMount mount: [String: Any]) -> [String: Any] {
        // type may be a string or a {"kind": {...}} discriminator object.
        var type = string(mount["type"])
        if type.isEmpty, let typeObject = mount["type"] as? [String: Any] {
            type = typeObject.keys.sorted().first ?? ""
        }
        let source = [string(mount["source"]), string(mount["name"])]
            .first { !$0.isEmpty } ?? ""
        let destination = [string(mount["destination"]), string(mount["target"]), string(mount["path"])]
            .first { !$0.isEmpty } ?? ""
        var row: [String: Any] = [
            "Source": source,
            "Destination": destination
        ]
        if !type.isEmpty { row["Type"] = type }
        if let readOnly = mount["readOnly"] as? Bool ?? mount["readonly"] as? Bool {
            row["RW"] = !readOnly
        }
        return row
    }

    /// `container inspect <id>` (one element) → `GET /containers/{id}/json` body.
    ///
    /// The synthesized body also carries the untouched CLI object under
    /// `"AppleContainer"` so the raw Inspect tab shows the original data
    /// alongside the Docker-shaped translation.
    static func containerInspectBody(fromAppleInspect element: [String: Any]) throws -> Data {
        let config = object(element["configuration"])
        let id = string(config["id"])
        let state = dockerState(fromAppleStatus: string(element["status"]))
        let initProcess = object(config["initProcess"])
        let executable = string(initProcess["executable"])
        let arguments = (initProcess["arguments"] as? [String]) ?? []
        let image = object(config["image"])

        var ipAddress = ""
        if let network = array(element["networks"]).first {
            // "192.168.64.2/24" → "192.168.64.2"
            ipAddress = string(network["ipv4Address"]).components(separatedBy: "/").first ?? ""
        }

        // Docker's Ports map: {"80/tcp": [{"HostIp": "…", "HostPort": "8080"}]}
        var portsMap: [String: Any] = [:]
        for port in array(config["publishedPorts"]) {
            let proto = string(port["proto"]).isEmpty ? "tcp" : string(port["proto"])
            let key = "\(int64(port["containerPort"]))/\(proto)"
            var binding: [String: Any] = ["HostPort": String(int64(port["hostPort"]))]
            let address = string(port["hostAddress"])
            if !address.isEmpty { binding["HostIp"] = address }
            portsMap[key] = [binding]
        }

        var mounts: [[String: Any]] = []
        for mount in array(config["mounts"]) {
            mounts.append(mountJSON(fromAppleMount: mount))
        }

        let body: [String: Any] = [
            "Id": id,
            "Created": iso8601(fromAppleDate: config["creationDate"] ?? element["startedDate"]),
            "Path": executable,
            "Args": arguments,
            "State": [
                "Status": state,
                "Running": state == "running",
                "Paused": false,
                "Restarting": false,
                "OOMKilled": false,
                "Pid": 0,
                "ExitCode": 0,
                "Error": "",
                "StartedAt": iso8601(fromAppleDate: element["startedDate"]),
                "FinishedAt": ""
            ],
            "Image": string(object(image["descriptor"])["digest"]),
            "Name": "/" + id,
            "RestartCount": 0,
            "Platform": string(object(config["platform"])["os"]),
            "HostConfig": [
                "NetworkMode": string(array(config["networks"]).first?["network"] ?? "default"),
                "Memory": int64(object(config["resources"])["memoryInBytes"]),
                "NanoCpus": int64(object(config["resources"])["cpus"]) * 1_000_000_000
            ],
            "Config": [
                "Hostname": string(array(element["networks"]).first?["hostname"]),
                "Domainname": string(object(config["dns"])["domain"]),
                "Env": (initProcess["environment"] as? [String]) ?? [],
                "Cmd": ([executable] + arguments).filter { !$0.isEmpty },
                "Image": string(image["reference"]),
                "Labels": (config["labels"] as? [String: String]) ?? [:],
                "Tty": (initProcess["terminal"] as? Bool) ?? false,
                "WorkingDir": string(initProcess["workingDirectory"]),
                "User": ""
            ],
            "NetworkSettings": [
                "IPAddress": ipAddress,
                "Ports": portsMap
            ],
            "Mounts": mounts,
            // The untranslated CLI object, for the raw Inspect tab.
            "AppleContainer": element
        ]
        return try encode(body)
    }

    // MARK: - Images

    /// `container image list --format json` → `GET /images/json` body.
    static func imagesListBody(fromAppleList data: Data) throws -> Data {
        let apple = array(try decode(data))
        var rows: [[String: Any]] = []
        for element in apple {
            let descriptor = object(element["descriptor"])
            let reference = string(element["reference"])
            rows.append([
                "Id": string(descriptor["digest"]),
                "ParentId": "",
                "RepoTags": reference.isEmpty ? [] : [displayReference(reference)],
                "RepoDigests": [],
                "Created": 0,
                "Size": bytes(fromLocalizedSize: string(element["fullSize"])),
                "SharedSize": -1,
                "Containers": -1,
                "Labels": [:]
            ])
        }
        return try encode(rows)
    }

    /// Strips the implicit registry prefix Docker also hides ("docker.io/library/").
    static func displayReference(_ reference: String) -> String {
        if reference.hasPrefix("docker.io/library/") {
            return String(reference.dropFirst("docker.io/library/".count))
        }
        if reference.hasPrefix("docker.io/") {
            return String(reference.dropFirst("docker.io/".count))
        }
        return reference
    }

    /// Maps an image identifier the app uses (a `sha256:` digest from a
    /// previous list) back to a CLI-addressable reference using that list.
    /// Falls through to the identifier itself (already a reference).
    static func imageReference(forID id: String, inAppleList data: Data?) -> String {
        guard id.hasPrefix("sha256:"), let data else { return id }
        guard let apple = try? decode(data) else { return id }
        for element in array(apple) {
            let descriptor = object(element["descriptor"])
            if string(descriptor["digest"]) == id {
                let reference = string(element["reference"])
                if !reference.isEmpty { return reference }
            }
        }
        return id
    }

    // MARK: - Volumes

    /// `container volume list --format json` → `GET /volumes` body.
    static func volumesListBody(fromAppleList data: Data) throws -> Data {
        let apple = array(try decode(data))
        let rows = apple.map(volumeJSON(fromAppleVolume:))
        return try encode(["Volumes": rows, "Warnings": []])
    }

    /// One CLI volume → Docker volume object (also the `/volumes/create` body).
    static func volumeJSON(fromAppleVolume element: [String: Any]) -> [String: Any] {
        // createdAt is an apple-epoch double in `list` output but an ISO
        // string in `inspect` output; accept both.
        let createdAt: String
        if let text = element["createdAt"] as? String {
            createdAt = text
        } else {
            createdAt = iso8601(fromAppleDate: element["createdAt"])
        }
        var row: [String: Any] = [
            "Name": string(element["name"]),
            "Driver": string(element["driver"]).isEmpty ? "local" : string(element["driver"]),
            "Mountpoint": string(element["source"]),
            "CreatedAt": createdAt,
            "Labels": (element["labels"] as? [String: String]) ?? [:],
            "Scope": "local",
            "Options": (element["options"] as? [String: String]) ?? [:]
        ]
        let size = int64(element["sizeInBytes"])
        if size > 0 {
            row["UsageData"] = ["Size": size, "RefCount": -1]
        }
        return row
    }

    // MARK: - Networks

    /// `container network list --format json` → `GET /networks` body.
    static func networksListBody(fromAppleList data: Data) throws -> Data {
        let apple = array(try decode(data))
        var rows: [[String: Any]] = []
        for element in apple {
            let config = object(element["config"])
            let status = object(element["status"])
            let id = string(element["id"]).isEmpty ? string(config["id"]) : string(element["id"])

            var ipamConfig: [[String: Any]] = []
            let subnet = string(status["ipv4Subnet"])
            if !subnet.isEmpty {
                var entry: [String: Any] = ["Subnet": subnet]
                let gateway = string(status["ipv4Gateway"])
                if !gateway.isEmpty { entry["Gateway"] = gateway }
                ipamConfig.append(entry)
            }
            let subnetV6 = string(status["ipv6Subnet"])
            if !subnetV6.isEmpty {
                ipamConfig.append(["Subnet": subnetV6])
            }

            rows.append([
                "Id": id,
                "Name": id,
                "Created": iso8601(fromAppleDate: config["creationDate"]),
                "Scope": "local",
                "Driver": string(config["mode"]).isEmpty ? "nat" : string(config["mode"]),
                "EnableIPv6": !subnetV6.isEmpty,
                "Internal": false,
                "Attachable": true,
                "Ingress": false,
                "IPAM": ["Driver": "default", "Config": ipamConfig],
                "Labels": (config["labels"] as? [String: String]) ?? [:]
            ])
        }
        return try encode(rows)
    }

    // MARK: - Stats

    /// One entry of `container stats --no-stream --format json` plus a
    /// synthetic system-CPU clock → Docker `/containers/{id}/stats` body.
    ///
    /// Docker derives CPU%, as `(cpuΔ / systemΔ) × onlineCPUs × 100`, from two
    /// cumulative counters. apple/container reports only the container's
    /// cumulative `cpuUsageUsec`, so the "system" counter is synthesized as
    /// `monotonic-clock × onlineCPUs` — the deltas then divide out to
    /// CPU-seconds per wall-second, exactly what `docker stats` shows.
    /// `previous` (the prior synthesized sample) populates `precpu_stats`, so
    /// the decoder's own delta math also works for streamed samples.
    static func statsBody(
        fromAppleStats element: [String: Any],
        onlineCPUs: Int,
        monotonicNanoseconds: UInt64,
        previous: (cpuTotal: Int64, system: Int64)? = nil
    ) throws -> Data {
        let cpus = max(onlineCPUs, 1)
        let cpuTotal = int64(element["cpuUsageUsec"]) * 1_000
        let clock = Int64(clamping: monotonicNanoseconds)
        let system = clock.multipliedReportingOverflow(by: Int64(cpus)).partialValue

        var body: [String: Any] = [
            "read": "",
            "cpu_stats": [
                "cpu_usage": ["total_usage": cpuTotal],
                "system_cpu_usage": system,
                "online_cpus": cpus
            ],
            "memory_stats": [
                "usage": int64(element["memoryUsageBytes"]),
                "limit": int64(element["memoryLimitBytes"])
            ],
            "networks": [
                "eth0": [
                    "rx_bytes": int64(element["networkRxBytes"]),
                    "tx_bytes": int64(element["networkTxBytes"])
                ]
            ],
            "blkio_stats": [
                "io_service_bytes_recursive": [
                    ["op": "read", "value": int64(element["blockReadBytes"])],
                    ["op": "write", "value": int64(element["blockWriteBytes"])]
                ]
            ],
            "pids_stats": ["current": int64(element["numProcesses"])]
        ]
        // Without a previous sample the decoder would compute a meaningless
        // percent from zeroed precpu counters; pinning precpu to the current
        // values makes the first sample report exactly 0%, like docker's CLI.
        let baseline = previous ?? (cpuTotal: cpuTotal, system: system)
        body["precpu_stats"] = [
            "cpu_usage": ["total_usage": baseline.cpuTotal],
            "system_cpu_usage": baseline.system
        ]
        return try encode(body)
    }

    /// Picks the entry for `id` out of the CLI's all-containers stats array.
    static func statsEntry(forID id: String, inAppleStats data: Data) throws -> [String: Any]? {
        array(try decode(data)).first { string($0["id"]) == id }
    }

    // MARK: - System

    /// `container system df --format json` → `GET /system/df` body.
    ///
    /// `SystemDiskUsage` derives counts from array lengths and sizes from row
    /// sums, so each category synthesizes `total` rows with the aggregate size
    /// on the first row.
    static func dfBody(fromAppleDF data: Data) throws -> Data {
        let apple = object(try decode(data))

        func rows(_ category: String, sizeKey: String) -> [[String: Any]] {
            let entry = object(apple[category])
            let total = Int(int64(entry["total"]))
            let size = int64(entry["sizeInBytes"])
            guard total > 0 else { return [] }
            var result: [[String: Any]] = [[sizeKey: size]]
            result.append(contentsOf: Array(repeating: [sizeKey: Int64(0)], count: total - 1))
            return result
        }

        let body: [String: Any] = [
            "LayersSize": int64(object(apple["images"])["sizeInBytes"]),
            "Images": rows("images", sizeKey: "Size"),
            "Containers": rows("containers", sizeKey: "SizeRw"),
            "Volumes": rows("volumes", sizeKey: "Size").map { ["UsageData": $0] }
        ]
        return try encode(body)
    }

    /// Synthesizes `GET /version` from the CLI's `system status --format json`.
    static func versionBody(appServerVersion: String) throws -> Data {
        try encode([
            "Version": extractVersionNumber(from: appServerVersion),
            "ApiVersion": "1.47",
            "Os": "darwin",
            "Arch": currentArchitecture(),
            "Platform": ["Name": "apple/container"]
        ])
    }

    /// "container-apiserver version 0.12.3 (build: release, …)" → "0.12.3".
    static func extractVersionNumber(from text: String) -> String {
        let pattern = /(\d+\.\d+(\.\d+)?)/
        if let match = text.firstMatch(of: pattern) {
            return String(match.1)
        }
        return text
    }

    /// Synthesizes `GET /info`. Container/image counts come from the live
    /// lists; CPU and memory describe the Mac itself (each container runs in
    /// its own lightweight VM, so the host's capacity is the honest ceiling).
    static func infoBody(
        containersTotal: Int,
        containersRunning: Int,
        imagesCount: Int,
        serverVersion: String,
        ncpu: Int,
        memTotal: Int64,
        hostName: String
    ) throws -> Data {
        try encode([
            "Containers": containersTotal,
            "ContainersRunning": containersRunning,
            "ContainersPaused": 0,
            "ContainersStopped": containersTotal - containersRunning,
            "Images": imagesCount,
            "ServerVersion": extractVersionNumber(from: serverVersion),
            "Name": hostName,
            "OperatingSystem": "macOS (apple/container)",
            "OSType": "darwin",
            "Architecture": currentArchitecture(),
            "MemTotal": memTotal,
            "NCPU": ncpu
        ])
    }

    static func currentArchitecture() -> String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    // MARK: - Pull progress

    /// One line of `container image pull --progress plain` → one Docker
    /// pull-progress JSON line. Percentages become current/total so the UI's
    /// progress bar moves.
    static func pullProgressJSON(fromCLILine line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var body: [String: Any] = ["status": trimmed]
        if let match = trimmed.firstMatch(of: /(\d+)%/), let percent = Int(match.1) {
            body["progressDetail"] = ["current": percent, "total": 100]
        }
        return body
    }

    // MARK: - Prune output

    /// Counts the identifiers a prune command printed (one per line) and
    /// extracts a "freed/reclaimed N <unit>" figure when present.
    static func pruneBody(
        fromCLIOutput output: String,
        deletedKey: String
    ) throws -> Data {
        var deleted: [String] = []
        var reclaimed: Int64 = 0
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let match = line.firstMatch(of: /(?i)(?:freed|reclaimed)\s+(.+)$/) {
                reclaimed = bytes(fromLocalizedSize: String(match.1))
                continue
            }
            // Identifier-looking lines (no spaces) are deleted object names.
            if !line.contains(" ") {
                deleted.append(line)
            }
        }
        let entries: Any = deletedKey == "ImagesDeleted" || deletedKey == "CachesDeleted"
            ? deleted.map { ["Deleted": $0] }
            : deleted
        return try encode([deletedKey: entries, "SpaceReclaimed": reclaimed])
    }

    // MARK: - Processes (docker top emulation)

    /// Parses `ps aux`-style output into Docker's `/containers/{id}/top` shape:
    /// the header row becomes `Titles` and each following row is split into
    /// exactly `titles.count` columns (the trailing command keeps its spaces).
    static func topBody(fromPSOutput output: String) throws -> Data {
        let lines = output.split(separator: "\n").map(String.init)
        guard let header = lines.first else {
            return try encode(["Titles": [], "Processes": []])
        }
        let titles = header.split(separator: " ").map(String.init)
        var processes: [[String]] = []
        for line in lines.dropFirst() {
            let cells = splitColumns(line, count: titles.count)
            if !cells.isEmpty { processes.append(cells) }
        }
        return try encode(["Titles": titles, "Processes": processes])
    }

    /// Splits a row into `count` columns on whitespace; the final column keeps
    /// the remainder of the line (commands contain spaces).
    static func splitColumns(_ line: String, count: Int) -> [String] {
        guard count > 0 else { return [] }
        var cells: [String] = []
        var remainder = Substring(line)
        for _ in 0 ..< (count - 1) {
            let trimmedStart = remainder.drop(while: { $0 == " " || $0 == "\t" })
            guard let end = trimmedStart.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                // Fewer columns than titles: pad below.
                remainder = trimmedStart
                if !remainder.isEmpty {
                    cells.append(String(remainder))
                    remainder = ""
                }
                break
            }
            cells.append(String(trimmedStart[..<end]))
            remainder = trimmedStart[end...]
        }
        let last = remainder.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty, cells.count < count { cells.append(last) }
        guard !cells.isEmpty else { return [] }
        while cells.count < count { cells.append("") }
        return cells
    }
}
