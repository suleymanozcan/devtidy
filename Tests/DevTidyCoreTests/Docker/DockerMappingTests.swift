import Foundation
import Testing
@testable import DevTidyCore

@Suite("DockerMapping")
struct DockerMappingTests {
    private func decodeList(_ json: String) throws -> [WireContainerSummary] {
        try JSONDecoder().decode([WireContainerSummary].self, from: Data(json.utf8))
    }

    private func mapAll(_ json: String) throws -> [DockerContainer] {
        try decodeList(json).compactMap { DockerMapping.container(from: $0, startedAt: nil, stats: nil) }
    }

    private func container(_ id: String, in containers: [DockerContainer]) throws -> DockerContainer {
        try #require(containers.first { $0.id == id })
    }

    private func epoch(_ text: String) throws -> Double {
        let date = try #require(DockerTimestamp.parse(text))
        return date.timeIntervalSince1970
    }

    // MARK: Exact mapping (ENV §7.3 / §7.4 / §7.9 shapes)

    @Test func composeContainerWithCommasInDependsOnLabelAndHostMountPrefix() throws {
        let nginx = try container(S3Fixtures.nginxID, in: try mapAll(S3Fixtures.envListJSON))
        let started = S3Fixtures.date(1_792_172_110.5)
        let mapped = try #require(DockerMapping.container(from: try decodeList(S3Fixtures.envListJSON)[0], startedAt: started, stats: nil))

        let expected = DockerContainer(
            id: S3Fixtures.nginxID, shortID: "4b90705d7188", name: "tunahan-nginx-1", image: "nginx:1.29-alpine",
            state: .running, statusText: "Up 14 hours", createdAt: S3Fixtures.date(1_792_172_104), startedAt: started,
            composeProject: "tunahan", composeService: "nginx", composeWorkingDir: S3Fixtures.tunahanDir,
            publishedPorts: [
                PublishedPort(hostIP: "127.0.0.1", hostPort: 8000, containerPort: 80, proto: "tcp"),
                PublishedPort(hostIP: "127.0.0.1", hostPort: 8001, containerPort: 81, proto: "tcp"),
            ],
            bindMountSources: ["\(S3Fixtures.tunahanDir)/docker/nginx/default.conf"],
            health: nil, cpuPercent: nil, memoryBytes: nil, memoryLimitBytes: nil)
        #expect(mapped == expected)
        // The depends_on value contains commas; it must not have leaked into any other label-derived field.
        #expect(nginx.composeProject == "tunahan")
        #expect(nginx.composeService == "nginx")
    }

    @Test func standaloneContainerHasNoComposeFieldsAndCollapsesIPv6Twins() throws {
        let hindsight = try container(S3Fixtures.hindsightID, in: try mapAll(S3Fixtures.envListJSON))
        #expect(hindsight.name == "hindsight")
        #expect(hindsight.composeProject == nil)
        #expect(hindsight.composeService == nil)
        #expect(hindsight.composeWorkingDir == nil)
        // 127.0.0.1:8888 and its ::1 twin collapse to one entry; named volumes are not bind mounts.
        #expect(hindsight.publishedPorts == [
            PublishedPort(hostIP: "127.0.0.1", hostPort: 8888, containerPort: 8888, proto: "tcp"),
            PublishedPort(hostIP: "127.0.0.1", hostPort: 9999, containerPort: 9999, proto: "tcp"),
        ])
        #expect(hindsight.bindMountSources.isEmpty)
        // No `Health` object: falls back to the Status text suffix.
        #expect(hindsight.health == .healthy)
    }

    @Test func exitedContainerWithStaleHealthHasNoHealthAndNoStartedAt() throws {
        let redis = try container(S3Fixtures.redisID, in: try mapAll(S3Fixtures.envListJSON))
        #expect(redis.state == .exited)
        #expect(redis.health == nil)                      // `Health.Status == "unhealthy"` is stale for a stopped container (ENV G8)
        #expect(redis.startedAt == nil)
        #expect(redis.cpuPercent == nil && redis.memoryBytes == nil && redis.memoryLimitBytes == nil)
        #expect(redis.publishedPorts.isEmpty)             // `"Ports": []`
        #expect(redis.statusText == "Exited (0) 12 hours ago")
        #expect(redis.composeProject == "rentacar-api")
    }

    @Test func healthFromStatusTextSuffix() throws {
        let all = try mapAll(S3Fixtures.envListJSON)
        #expect(try container(S3Fixtures.e2eQueueID, in: all).health == .unhealthy)
        #expect(try container(S3Fixtures.phpID, in: all).health == .starting)
        #expect(try container(S3Fixtures.nginxID, in: all).health == nil)
        #expect(DockerMapping.health(fromStatusText: "Up 3 hours (healthy)") == .healthy)
        #expect(DockerMapping.health(fromStatusText: "Up 3 hours (unhealthy)") == .unhealthy)
        #expect(DockerMapping.health(fromStatusText: "Up 3 hours") == nil)
        #expect(DockerMapping.health(fromStatusText: nil) == nil)
    }

    @Test func healthObjectTakesPrecedenceForRunningContainers() throws {
        let json = #"""
        [{"Id":"\#(S3Fixtures.idA)","Names":["/a"],"State":"running","Status":"Up 1 minute","Health":{"Status":"healthy"}},
         {"Id":"\#(S3Fixtures.idB)","Names":["/b"],"State":"running","Status":"Up 1 minute (healthy)","Health":{"Status":"none"}},
         {"Id":"\#(S3Fixtures.idC)","Names":["/c"],"State":"paused","Status":"Up 1 minute (Paused)","Health":{"Status":"healthy"}}]
        """#
        let containers = try mapAll(json)
        #expect(try container(S3Fixtures.idA, in: containers).health == .healthy)
        #expect(try container(S3Fixtures.idB, in: containers).health == .healthy)   // "none" falls back to the text
        #expect(try container(S3Fixtures.idC, in: containers).health == nil)        // not running
    }

    @Test func unknownStateMapsToUnknown() throws {
        let json = #"[{"Id":"\#(S3Fixtures.idA)","Names":["/odd"],"State":"frozen","Status":"???"}]"#
        let odd = try #require(try mapAll(json).first)
        #expect(odd.state == .unknown)
        #expect(!odd.isRunning)
        #expect(DockerMapping.state(nil) == .unknown)
        #expect(DockerMapping.state("Running") == .running)
        for raw in ["created", "running", "paused", "restarting", "removing", "exited", "dead"] {
            #expect(DockerMapping.state(raw).rawValue == raw)
        }
    }

    // MARK: Tolerance

    @Test func everyFieldIsOptional() throws {
        let containers = try mapAll(#"[{"Id":"\#(S3Fixtures.idA)"}]"#)
        let bare = try #require(containers.first)
        #expect(bare.name == String(S3Fixtures.idA.prefix(12)))
        #expect(bare.image == "")
        #expect(bare.state == .unknown)
        #expect(bare.statusText == "")
        #expect(bare.publishedPorts.isEmpty && bare.bindMountSources.isEmpty)
        #expect(bare.startedAt == nil)
    }

    @Test func entriesWithoutAnIdAreDropped() throws {
        let wires = try decodeList(#"[{"Names":["/x"]},{"Id":"","Names":["/y"]}]"#)
        #expect(wires.compactMap { DockerMapping.container(from: $0, startedAt: nil, stats: nil) }.isEmpty)
    }

    @Test func fieldsOfTheWrongTypeDegradeToNilInsteadOfFailingTheList() throws {
        let json = #"[{"Id":"\#(S3Fixtures.idA)","Names":"not-an-array","Created":"yesterday","Ports":{"x":1},"Labels":[1,2],"State":"running"}]"#
        let container = try #require(try mapAll(json).first)
        #expect(container.state == .running)
        #expect(container.publishedPorts.isEmpty)
        #expect(container.composeProject == nil)
    }

    @Test func startedAtFallsBackToCreatedForRunningContainersOnly() throws {
        let all = try mapAll(S3Fixtures.envListJSON)
        let nginx = try container(S3Fixtures.nginxID, in: all)
        #expect(nginx.startedAt == nginx.createdAt)       // inspect did not provide one
        #expect(try container(S3Fixtures.mailpitID, in: all).startedAt == nil)
    }

    @Test func statsAreAppliedToRunningContainersOnly() throws {
        let wires = try decodeList(S3Fixtures.envListJSON)
        let stats = DockerContainerStats(cpuPercent: 12.5, memoryBytes: 1_000, memoryLimitBytes: 2_000)
        let running = try #require(DockerMapping.container(from: wires[0], startedAt: nil, stats: stats))
        #expect(running.cpuPercent == 12.5 && running.memoryBytes == 1_000 && running.memoryLimitBytes == 2_000)
        let exited = try #require(DockerMapping.container(from: wires[4], startedAt: nil, stats: stats))
        #expect(exited.cpuPercent == nil && exited.memoryBytes == nil && exited.memoryLimitBytes == nil)
    }

    // MARK: Names, ports, mounts

    @Test func canonicalNameSkipsLinkAliases() {
        #expect(DockerMapping.name(from: ["/web/db", "/db"], fallback: "fb") == "db")
        #expect(DockerMapping.name(from: ["/only"], fallback: "fb") == "only")
        #expect(DockerMapping.name(from: ["/a/b"], fallback: "fb") == "a/b")
        #expect(DockerMapping.name(from: [], fallback: "fb") == "fb")
        #expect(DockerMapping.name(from: nil, fallback: "fb") == "fb")
    }

    @Test func publishedPortsSkipExposedOnlyAndSortByHostPort() throws {
        let wires = try JSONDecoder().decode([WirePort].self, from: Data(#"""
        [{"IP":"0.0.0.0","PrivatePort":443,"PublicPort":8443,"Type":"tcp"},
         {"PrivatePort":9000,"Type":"tcp"},
         {"IP":"","PrivatePort":53,"PublicPort":5353,"Type":"UDP"},
         {"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},
         {"IP":"::","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},
         {"IP":"0.0.0.0","PrivatePort":1,"PublicPort":70000,"Type":"tcp"}]
        """#.utf8))
        #expect(DockerMapping.publishedPorts(wires) == [
            PublishedPort(hostIP: nil, hostPort: 5353, containerPort: 53, proto: "udp"),
            PublishedPort(hostIP: "0.0.0.0", hostPort: 8080, containerPort: 80, proto: "tcp"),
            PublishedPort(hostIP: "0.0.0.0", hostPort: 8443, containerPort: 443, proto: "tcp"),
        ])
    }

    @Test func hostMountPrefixIsStrippedOnlyAsAPathPrefix() throws {
        #expect(DockerMapping.stripHostMount("/host_mnt/Users/x/proj") == "/Users/x/proj")
        #expect(DockerMapping.stripHostMount("/host_mnt") == "/host_mnt")
        #expect(DockerMapping.stripHostMount("/host_mnt_other/x") == "/host_mnt_other/x")
        #expect(DockerMapping.stripHostMount("/Users/x") == "/Users/x")
        let mounts = try JSONDecoder().decode([WireMount].self, from: Data(#"""
        [{"Type":"bind","Source":"/host_mnt/Users/x/a","Destination":"/a"},
         {"Type":"bind","Source":"/host_mnt/Users/x/a","Destination":"/a2"},
         {"Type":"volume","Source":"/var/lib/docker/volumes/v/_data","Destination":"/v"},
         {"Type":"bind","Source":"/Users/x/b","Destination":"/b"},
         {"Type":"bind","Destination":"/nosource"}]
        """#.utf8))
        #expect(DockerMapping.bindMountSources(mounts) == ["/Users/x/a", "/Users/x/b"])
    }

    // MARK: Grouping

    @Test func groupingYieldsThreeProjectsAndOneStandalone() throws {
        let grouped = DockerGrouping.group(try mapAll(S3Fixtures.envListJSON))
        #expect(grouped.projects.map(\.name) == ["eticaretsaas-monolith", "rentacar-api", "tunahan"])
        #expect(grouped.standalone.map(\.name) == ["hindsight"])

        let tunahan = try #require(grouped.projects.first { $0.name == "tunahan" })
        #expect(tunahan.workingDir == S3Fixtures.tunahanDir)
        // Sorted by service, then name: e2e-queue, nginx, php.
        #expect(tunahan.containers.map(\.name) == ["tunahan-e2e-queue-1", "tunahan-nginx-1", "tunahan-php-1"])
        #expect(tunahan.runningCount == 3)

        let rentacar = try #require(grouped.projects.first { $0.name == "rentacar-api" })
        #expect(rentacar.workingDir == "/Users/suleymanozcan/developer/rentacarsaas/monolith-api")
        #expect(rentacar.runningCount == 0)
    }

    @Test func groupingOrdersByServiceThenNameAndTakesTheFirstWorkingDir() throws {
        let json = #"""
        [{"Id":"\#(S3Fixtures.idA)","Names":["/p-web-2"],"State":"running","Labels":{"com.docker.compose.project":"p","com.docker.compose.service":"web"}},
         {"Id":"\#(S3Fixtures.idB)","Names":["/p-web-1"],"State":"running","Labels":{"com.docker.compose.project":"p","com.docker.compose.service":"web","com.docker.compose.project.working_dir":"/w"}},
         {"Id":"\#(S3Fixtures.idC)","Names":["/p-api-1"],"State":"exited","Labels":{"com.docker.compose.project":"p","com.docker.compose.service":"api","com.docker.compose.project.working_dir":"/other"}}]
        """#
        let grouped = DockerGrouping.group(try mapAll(json))
        #expect(grouped.projects.count == 1)
        #expect(grouped.projects[0].containers.map(\.name) == ["p-api-1", "p-web-1", "p-web-2"])
        #expect(grouped.projects[0].workingDir == "/w")            // first container, in input order, that carries the label
        #expect(grouped.standalone.isEmpty)
    }

    // MARK: Build cache

    @Test func buildCacheSummaryMath() throws {
        let json = #"""
        {"LayersSize":1,"BuildCache":[
          {"ID":"a","Size":1000,"InUse":false,"Shared":false},
          {"ID":"b","Size":2000,"InUse":false,"Shared":true},
          {"ID":"c","Size":4000,"InUse":true,"Shared":false},
          {"ID":"d","Size":8000}]}
        """#
        let usage = try JSONDecoder().decode(WireDiskUsage.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_000)
        let summary = DockerBuildCache.summarize(usage.buildCache ?? [], measuredAt: now)
        #expect(summary == BuildCacheSummary(totalBytes: 15_000, reclaimableBytes: 11_000, privateReclaimableBytes: 9_000,
                                             recordCount: 4, activeCount: 1, measuredAt: now))
    }

    @Test func buildCacheSummaryToleratesMissingFields() throws {
        let missing = try JSONDecoder().decode(WireDiskUsage.self, from: Data(#"{"LayersSize":5}"#.utf8))
        let now = Date(timeIntervalSince1970: 5)
        #expect(DockerBuildCache.summarize(missing.buildCache ?? [], measuredAt: now)
                == BuildCacheSummary(totalBytes: 0, reclaimableBytes: 0, privateReclaimableBytes: 0, recordCount: 0, activeCount: 0, measuredAt: now))
        let nulls = try JSONDecoder().decode(WireDiskUsage.self, from: Data(#"{"BuildCache":null}"#.utf8))
        #expect(nulls.buildCache == nil)
        let weird = try JSONDecoder().decode(WireDiskUsage.self, from: Data(#"{"BuildCache":[{"Size":"big","InUse":"yes"},{"Size":-5}]}"#.utf8))
        let summary = DockerBuildCache.summarize(weird.buildCache ?? [], measuredAt: now)
        #expect(summary.recordCount == 2 && summary.totalBytes == 0 && summary.activeCount == 0)
    }

    // MARK: Timestamps

    @Test func rfc3339WithNanoseconds() throws {
        let date = try #require(DockerTimestamp.parse("2026-10-16T17:35:10.54781071Z"))
        #expect(abs(date.timeIntervalSince1970 - 1_792_172_110.54781071) < 0.001)
    }

    @Test func rfc3339VariantsAndOffsets() throws {
        let base = 1_792_172_110.0
        #expect(try epoch("2026-10-16T17:35:10Z") == base)
        #expect(try epoch("2026-10-16T20:35:10+03:00") == base)
        #expect(try epoch("2026-10-16T12:35:10-05:00") == base)
        #expect(abs(try epoch("2026-10-16T17:35:10.5Z") - (base + 0.5)) < 1e-6)
        #expect(try epoch("1970-01-01T00:00:00Z") == 0)
    }

    @Test(arguments: ["", "yesterday", "2026-10-16", "2026-10-16T17:35:10", "2026-13-16T17:35:10Z", "2026-10-16T25:35:10Z",
                      "2026-10-16T17:35:10.Z", "2026-10-16T17:35:10Zjunk", "2026-10-16T17:35:10+0300"])
    func rfc3339GarbageIsNil(text: String) {
        #expect(DockerTimestamp.parse(text) == nil)
    }

    @Test func zeroTimeMeansNeverStarted() throws {
        let inspect = try JSONDecoder().decode(WireInspect.self, from: Data(#"{"State":{"StartedAt":"0001-01-01T00:00:00Z"}}"#.utf8))
        #expect(DockerMapping.startedAt(fromInspect: inspect) == nil)
        let real = try JSONDecoder().decode(WireInspect.self, from: Data(#"{"State":{"StartedAt":"2026-10-16T17:35:10.54781071Z"}}"#.utf8))
        #expect(DockerMapping.startedAt(fromInspect: real) != nil)
    }
}
