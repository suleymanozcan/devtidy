import Foundation

/// Everything `DevTidyStore` talks to. Tests build one from fakes; the app uses `live(socketOverride:)`.
public struct DevTidyServices: Sendable {
    public let scanner: any ProcessScanning
    public let classifier: any ServerClassifying
    public let terminator: any ProcessTerminating
    public let catalog: any CacheCataloging
    public let cleaner: any CacheCleaning
    public let docker: any DockerControlling
    public let identities: any ProjectIdentifying
    public let pageTitles: any PageTitleFetching
    public let audit: any AuditLogging
    public let now: @Sendable () -> Date

    public init(scanner: any ProcessScanning, classifier: any ServerClassifying, terminator: any ProcessTerminating,
                catalog: any CacheCataloging, cleaner: any CacheCleaning, docker: any DockerControlling,
                identities: any ProjectIdentifying, pageTitles: any PageTitleFetching,
                audit: any AuditLogging, now: @escaping @Sendable () -> Date = { Date() }) {
        self.scanner = scanner
        self.classifier = classifier
        self.terminator = terminator
        self.catalog = catalog
        self.cleaner = cleaner
        self.docker = docker
        self.identities = identities
        self.pageTitles = pageTitles
        self.audit = audit
        self.now = now
    }

    /// Composition root: the only place concrete service types are named. `audit` defaults to the real
    /// `~/Library/Logs/DevTidy/cleanup.log`; the live smoke test passes a temporary one.
    public static func live(socketOverride: @escaping @Sendable () -> String?, audit: AuditLog = AuditLog()) -> DevTidyServices {
        let locator = ToolLocator()
        let runner = ProcessCommandRunner()
        let scanner = LiveProcessScanner()
        let projects = ProjectDetector()
        let classifier = ServerClassifier(projects: projects)
        let terminator = TreeTerminator(scanner: scanner, audit: audit)
        let catalog = CacheCatalog(projects: projects, runner: runner, locator: locator)
        let docker = DockerClient(locator: locator, runner: runner, audit: audit, socketOverride: socketOverride)
        let activity = LiveActivityChecker(scanner: scanner, docker: docker, classifier: classifier)
        let cleaner = CacheCleaner(catalog: catalog, activity: activity, audit: audit)
        return DevTidyServices(scanner: scanner, classifier: classifier, terminator: terminator,
                            catalog: catalog, cleaner: cleaner, docker: docker,
                            identities: projects, pageTitles: PageTitleFetcher(), audit: audit)
    }
}
