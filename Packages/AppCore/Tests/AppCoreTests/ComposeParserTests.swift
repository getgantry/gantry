import Foundation
import Testing
@testable import AppCore

struct ComposeParserTests {
    let parser = ComposeParser()
    let file = URL(fileURLWithPath: "/tmp/myproject/docker-compose.yml")
    let dir = URL(fileURLWithPath: "/tmp/myproject")

    private func parse(_ yaml: String, env: [String: String] = [:]) throws -> ComposeProject {
        try parser.parse(text: yaml, fileURL: file, directory: dir, environment: env)
    }

    @Test func projectNameFromDirectory() throws {
        let p = try parse("""
        services:
          web:
            image: nginx
        """)
        #expect(p.name == "myproject")
        #expect(p.services.count == 1)
        #expect(p.services[0].name == "web")
        #expect(p.services[0].image == "nginx")
    }

    @Test func explicitProjectName() throws {
        let p = try parse("""
        name: shop
        services:
          web: { image: nginx }
        """)
        #expect(p.name == "shop")
    }

    @Test func noServicesThrows() {
        #expect(throws: ComposeParseError.self) {
            _ = try parse("version: '3'\nvolumes:\n  data: {}")
        }
    }

    @Test func serviceWithoutImageOrBuildThrows() {
        #expect(throws: ComposeParseError.self) {
            _ = try parse("services:\n  web:\n    ports: ['80:80']")
        }
    }

    @Test func portsListAndMapForms() throws {
        let p = try parse("""
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
              - "127.0.0.1:9000:9000/udp"
              - "3000"
              - target: 5000
                published: 5001
                protocol: tcp
        """)
        let ports = p.services[0].ports
        #expect(ports.count == 4)
        #expect(ports[0] == ComposePort(hostPort: "8080", containerPort: "80", proto: "tcp"))
        #expect(ports[1] == ComposePort(hostIP: "127.0.0.1", hostPort: "9000", containerPort: "9000", proto: "udp"))
        #expect(ports[2] == ComposePort(hostPort: nil, containerPort: "3000", proto: "tcp"))
        #expect(ports[3] == ComposePort(hostPort: "5001", containerPort: "5000", proto: "tcp"))
    }

    @Test func environmentListAndMap() throws {
        let listForm = try parse("""
        services:
          web:
            image: nginx
            environment:
              - FOO=bar
              - BAZ=qux
        """)
        #expect(listForm.services[0].environment.map { [$0.key, $0.value] }
            == [["FOO", "bar"], ["BAZ", "qux"]])

        let mapForm = try parse("""
        services:
          web:
            image: nginx
            environment:
              A: "1"
              B: "2"
        """)
        let env = Dictionary(uniqueKeysWithValues: mapForm.services[0].environment.map { ($0.key, $0.value) })
        #expect(env["A"] == "1")
        #expect(env["B"] == "2")
    }

    @Test func variableInterpolation() throws {
        let p = try parse("""
        services:
          web:
            image: "nginx:${TAG:-latest}"
            environment:
              - HOST=${HOSTNAME}
              - PORT=${PORT:-8080}
              - LITERAL=$$NOTVAR
        """, env: ["HOSTNAME": "example.com"])
        #expect(p.services[0].image == "nginx:latest")
        let env = Dictionary(uniqueKeysWithValues: p.services[0].environment.map { ($0.key, $0.value) })
        #expect(env["HOST"] == "example.com")
        #expect(env["PORT"] == "8080")
        #expect(env["LITERAL"] == "$NOTVAR")
    }

    @Test func bindAndNamedVolumes() throws {
        let p = try parse("""
        services:
          db:
            image: postgres
            volumes:
              - ./data:/var/lib/postgresql/data
              - pgdata:/var/lib/postgresql/backup:ro
              - /etc/conf:/conf
        volumes:
          pgdata: {}
        """)
        let mounts = p.services[0].volumes
        #expect(mounts.count == 3)
        #expect(mounts[0].kind == .bind(hostPath: "./data"))
        #expect(mounts[0].containerPath == "/var/lib/postgresql/data")
        #expect(mounts[1].kind == .named(volume: "pgdata"))
        #expect(mounts[1].readOnly == true)
        #expect(mounts[2].kind == .bind(hostPath: "/etc/conf"))
        #expect(p.volumes["pgdata"] != nil)
    }

    @Test func buildStringAndMap() throws {
        let strForm = try parse("""
        services:
          api:
            build: ./api
        """)
        #expect(strForm.services[0].build?.context == "./api")

        let mapForm = try parse("""
        services:
          api:
            build:
              context: ./api
              dockerfile: Dockerfile.prod
              target: runtime
              args:
                VERSION: "1.2"
        """)
        let b = mapForm.services[0].build
        #expect(b?.context == "./api")
        #expect(b?.dockerfile == "Dockerfile.prod")
        #expect(b?.target == "runtime")
        #expect(b?.args["VERSION"] == "1.2")
    }

    @Test func dependsOnListAndMap() throws {
        let listForm = try parse("""
        services:
          web:
            image: nginx
            depends_on: [db, cache]
          db: { image: postgres }
          cache: { image: redis }
        """)
        #expect(Set(listForm.services.first { $0.name == "web" }!.dependsOn) == ["db", "cache"])

        let mapForm = try parse("""
        services:
          web:
            image: nginx
            depends_on:
              db:
                condition: service_started
          db: { image: postgres }
        """)
        #expect(mapForm.services.first { $0.name == "web" }!.dependsOn == ["db"])
    }

    @Test func commandStringTokenizes() throws {
        let p = try parse("""
        services:
          web:
            image: nginx
            command: nginx -g daemon off
            entrypoint: ["/bin/sh", "-c"]
        """)
        #expect(p.services[0].command == ["nginx", "-g", "daemon", "off"])
        #expect(p.services[0].entrypoint == ["/bin/sh", "-c"])
    }

    @Test func resourceLimits() throws {
        let p = try parse("""
        services:
          web:
            image: nginx
            mem_limit: 512m
            cpus: 1.5
        """)
        #expect(p.services[0].memoryBytes == Int64(536_870_912))
        #expect(p.services[0].cpus == 1.5)

        let deployForm = try parse("""
        services:
          web:
            image: nginx
            deploy:
              resources:
                limits:
                  memory: 1g
                  cpus: "2"
        """)
        #expect(deployForm.services[0].memoryBytes == Int64(1_073_741_824))
        #expect(deployForm.services[0].cpus == 2)
    }

    @Test func labelsAndRestart() throws {
        let p = try parse("""
        services:
          web:
            image: nginx
            restart: always
            labels:
              - com.example.foo=bar
              - keyonly=
        """)
        #expect(p.services[0].restart == "always")
        #expect(p.services[0].labels["com.example.foo"] == "bar")
    }

    @Test func defaultProjectNameSanitizes() {
        #expect(ComposeParser.defaultProjectName(directory: URL(fileURLWithPath: "/x/My App_2024")) == "my-app-2024")
        #expect(ComposeParser.defaultProjectName(directory: URL(fileURLWithPath: "/x/.hidden")) == "hidden")
    }

    @Test func byteSizeParsing() {
        #expect(ComposeParser.parseByteSize("512m") == Int64(536_870_912))
        #expect(ComposeParser.parseByteSize("1g") == Int64(1_073_741_824))
        #expect(ComposeParser.parseByteSize("2048") == Int64(2048))
    }
}
