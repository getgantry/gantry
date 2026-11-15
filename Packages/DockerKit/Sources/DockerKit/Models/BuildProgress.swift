import Foundation

/// The state of one build step, as the build log reports it.
public enum BuildStepState: String, Sendable, Codable, Equatable {
    case run
    case cached
    case failed
    /// The log has no result for the step (a cancelled or cut build).
    case unknown
}

/// One step of an image build: a BuildKit vertex (`#N <name>`) or a classic
/// Dockerfile instruction (`Step i/n : …`). Internal vertices count as
/// steps because `docker buildx history` counts them too.
public struct BuildStep: Sendable, Codable, Equatable, Identifiable {
    /// The vertex number (BuildKit) or the step index (classic).
    public var number: Int
    public var name: String
    public var state: BuildStepState
    /// Seconds, when the log gives them (`#N DONE 0.1s`).
    public var duration: Double?
    /// True for the steps that are not Dockerfile instructions.
    public var isInternal: Bool

    public var id: Int { number }

    public init(number: Int, name: String, state: BuildStepState, duration: Double? = nil, isInternal: Bool = false) {
        self.number = number
        self.name = name
        self.state = state
        self.duration = duration
        self.isInternal = isInternal
    }
}

/// The step counts of one build.
public struct BuildStepSummary: Sendable, Equatable {
    public var total: Int
    public var cached: Int
    public var run: Int
    public var failed: Int

    public init(total: Int, cached: Int, run: Int, failed: Int) {
        self.total = total
        self.cached = cached
        self.run = run
        self.failed = failed
    }

    public init(_ steps: [BuildStep]) {
        self.init(
            total: steps.count,
            cached: steps.filter { $0.state == .cached }.count,
            run: steps.filter { $0.state == .run }.count,
            failed: steps.filter { $0.state == .failed }.count
        )
    }
}

/// Finds the steps of a build in its log: BuildKit plain progress
/// (`container build --progress plain`, `docker buildx history logs`) or the
/// text of the classic Docker `/build` stream.
public enum BuildProgressParser {
    /// The steps of `log`. The classic stream sends its error as a separate
    /// line, so `failed` marks the last step without a cache hit as failed.
    public static func steps(fromLog log: String, failed: Bool = false) -> [BuildStep] {
        let lines = log.split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r" }.map(String.init)
        if lines.contains(where: { vertexLine($0) != nil }) {
            return buildKitSteps(lines)
        }
        return classicSteps(lines, failed: failed)
    }

    // MARK: - BuildKit plain progress

    /// `#12 rest` → (12, "rest").
    static func vertexLine(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        let body = line.dropFirst()
        guard let space = body.firstIndex(of: " "),
              let number = Int(body[..<space]), number >= 0 else { return nil }
        return (number, String(body[body.index(after: space)...]))
    }

    static func buildKitSteps(_ lines: [String]) -> [BuildStep] {
        var order: [Int] = []
        var steps: [Int: BuildStep] = [:]
        for line in lines {
            guard let (number, rest) = vertexLine(line) else { continue }
            guard var step = steps[number] else {
                // The first line of a vertex is its name; a vertex can show again later.
                order.append(number)
                steps[number] = BuildStep(
                    number: number, name: rest, state: .unknown, isInternal: !isDockerfileStep(rest)
                )
                continue
            }
            if rest == "CACHED" {
                step.state = .cached
            } else if rest.hasPrefix("ERROR") {
                step.state = .failed
            } else if rest.hasPrefix("DONE"), step.state != .cached, step.state != .failed {
                step.state = .run
                step.duration = seconds(rest.dropFirst("DONE".count))
            }
            steps[number] = step
        }
        return order.compactMap { steps[$0] }
    }

    /// `[2/4] RUN …`, `[linux/arm64 2/4] RUN …` or `[stage 2/4] …`.
    static func isDockerfileStep(_ name: String) -> Bool {
        guard name.hasPrefix("["), let close = name.firstIndex(of: "]") else { return false }
        let inside = name[name.index(after: name.startIndex)..<close]
        guard let last = inside.split(separator: " ").last else { return false }
        let parts = last.split(separator: "/")
        return parts.count == 2 && parts.allSatisfy { Int($0) != nil }
    }

    /// ` 0.1s` → 0.1.
    static func seconds(_ text: Substring) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("s") else { return nil }
        return Double(trimmed.dropLast())
    }

    // MARK: - Classic Docker stream

    static func classicSteps(_ lines: [String], failed: Bool) -> [BuildStep] {
        var steps: [BuildStep] = []
        for line in lines {
            if let name = classicStepName(line) {
                steps.append(BuildStep(number: steps.count + 1, name: name, state: .unknown))
                continue
            }
            guard !steps.isEmpty else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("--->") else { continue }
            let detail = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let index = steps.count - 1
            if detail == "Using cache" {
                steps[index].state = .cached
            } else if steps[index].state == .unknown,
                      detail.hasPrefix("Running in") || isLayerID(detail) {
                steps[index].state = .run
            }
        }
        // A failure after "Successfully built" (tagging) leaves the steps as they are.
        let built = lines.contains { $0.hasPrefix("Successfully built") }
        if failed, !built, let last = steps.indices.last, steps[last].state != .cached {
            steps[last].state = .failed
        }
        return steps
    }

    /// `Step 2/4 : RUN echo one` → `RUN echo one`.
    static func classicStepName(_ line: String) -> String? {
        guard line.hasPrefix("Step "), let colon = line.range(of: " : ") else { return nil }
        let counter = line[line.index(line.startIndex, offsetBy: 5)..<colon.lowerBound]
        let parts = counter.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// A short image or layer ID: 12 hex characters.
    static func isLayerID(_ text: String) -> Bool {
        text.count == 12 && text.allSatisfy(\.isHexDigit)
    }
}
