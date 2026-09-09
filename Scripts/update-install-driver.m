// Standalone, opt-in Sparkle installation fixture. Never linked into the App.
// The Python harness owns fixture creation, signing, launch, and final cleanup.
#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

static const uint64_t MaximumArchiveBytes = 1024ULL * 1024ULL * 1024ULL;
static NSString *Canonical(NSString *path) {
    if (path == nil) return nil;
    char *resolved = realpath(path.fileSystemRepresentation, NULL);
    if (resolved != NULL) {
        NSString *result = @(resolved); free(resolved); return result;
    }
    // Event files do not exist yet. Resolve their existing parent consistently;
    // Foundation otherwise treats existing /private/tmp and missing paths differently.
    NSString *parent = path.stringByDeletingLastPathComponent;
    if (parent.length == 0 || [parent isEqualToString:path]) return nil;
    NSString *resolvedParent = Canonical(parent);
    return [[resolvedParent stringByAppendingString:@"/"] stringByAppendingString:path.lastPathComponent];
}
static BOOL Inside(NSString *path, NSString *directory) {
    return [Canonical(path) hasPrefix:[Canonical(directory) stringByAppendingString:@"/"]];
}
static BOOL PrivateDirectory(NSString *path) {
    struct stat info;
    return lstat(path.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode)
        && info.st_uid == getuid() && (info.st_mode & 0777) == 0700;
}
static BOOL OwnedDirectory(NSString *path) {
    struct stat info;
    return lstat(path.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode)
        && info.st_uid == getuid();
}
static BOOL RegularFile(NSString *path) {
    struct stat info;
    return lstat(path.fileSystemRepresentation, &info) == 0 && S_ISREG(info.st_mode)
        && info.st_uid == getuid();
}
static BOOL LocalURL(NSURL *url) {
    return [url.scheme isEqualToString:@"http"] && [url.host isEqualToString:@"127.0.0.1"]
        && url.port.integerValue >= 1024 && url.port.integerValue <= 65535
        && url.user == nil && url.password == nil && url.fragment == nil;
}

@interface InstallDriver : NSObject <SPUUserDriver, SPUUpdaterDelegate>
@property(nonatomic) SPUUpdater *updater;
@property(nonatomic) NSString *hostPath;
@property(nonatomic) NSString *bundleID;
@property(nonatomic) NSString *expectedVersion;
@property(nonatomic) NSString *originalVersion;
@property(nonatomic) NSURL *feedURL;
@property(nonatomic) int eventsFD;
@property(nonatomic) NSUInteger eventIndex;
@property(nonatomic) pid_t oldPID;
@property(nonatomic) pid_t newPID;
@property(nonatomic) BOOL feedVerified;
@property(nonatomic) BOOL archiveDownloaded;
@property(nonatomic) BOOL installationPerformed;
@property(nonatomic) BOOL relaunched;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL installStarted;
@property(nonatomic) uint64_t receivedBytes;
@property(nonatomic) uint64_t expectedBytes;
@property(nonatomic) NSInteger extractionStep;
@property(nonatomic, copy) void (^cancelPending)(void);
@property(nonatomic) NSString *phase;
- (void)emit:(NSString *)type fields:(NSDictionary *)fields;
- (void)finish:(BOOL)success reason:(NSString *)reason;
- (void)fail:(NSString *)reason error:(NSError *)error;
- (NSArray<NSRunningApplication *> *)runningTargets;
- (void)startWithBundle:(NSBundle *)bundle;
@end

@implementation InstallDriver
- (void)emit:(NSString *)type fields:(NSDictionary *)fields {
    NSMutableDictionary *event = [fields mutableCopy] ?: [NSMutableDictionary dictionary];
    event[@"type"] = type;
    event[@"index"] = @(++self.eventIndex);
    event[@"uptime"] = @(NSProcessInfo.processInfo.systemUptime);
    event[@"expectedVersion"] = self.expectedVersion;
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys error:NULL];
    NSMutableData *line = [data mutableCopy];
    [line appendBytes:"\n" length:1];
    const uint8_t *bytes = line.bytes;
    NSUInteger remaining = line.length;
    while (remaining > 0) {
        ssize_t count = write(self.eventsFD, bytes, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) _exit(3);
        bytes += count; remaining -= (NSUInteger)count;
    }
}
- (NSArray<NSRunningApplication *> *)runningTargets {
    NSMutableArray *matches = [NSMutableArray array];
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:self.bundleID]) {
        if (!app.terminated && [Canonical(app.bundleURL.path) isEqualToString:self.hostPath]) [matches addObject:app];
    }
    return matches;
}
- (BOOL)originalTargetIsRunning {
    NSArray *targets = [self runningTargets];
    return targets.count == 1 && ((NSRunningApplication *)targets.firstObject).processIdentifier == self.oldPID;
}
- (void)finish:(BOOL)success reason:(NSString *)reason {
    if (self.finished) return;
    self.finished = YES;
    if (!success && !self.installStarted && self.cancelPending) {
        void (^cancel)(void) = self.cancelPending;
        self.cancelPending = nil;
        cancel();
    }
    [self emit:@"driver_finished" fields:@{
        @"success": @(success), @"exitCode": @(success ? 0 : 1), @"reason": reason,
        @"phase": self.phase ?: @"initializing", @"feedSignatureVerified": @(self.feedVerified),
        @"archiveDownloaded": @(self.archiveDownloaded), @"bytesDownloaded": @(self.receivedBytes),
        @"installationPerformed": @(self.installationPerformed), @"relaunched": @(self.relaunched),
        @"oldPID": @(self.oldPID), @"newPID": @(self.newPID),
        @"cameraUsed": @NO, @"installationMayStillBeRunning": @((BOOL)(!success && self.installStarted))
    }];
    fsync(self.eventsFD);
    dispatch_async(dispatch_get_main_queue(), ^{ close(self.eventsFD); exit(success ? 0 : 1); });
}
- (void)fail:(NSString *)reason error:(NSError *)error {
    if (self.finished) return;
    [self emit:@"error" fields:@{@"reason":reason, @"domain":error.domain ?: @"UpdateInstallFixture", @"code":@(error.code)}];
    [self finish:NO reason:reason];
}
- (void)startWithBundle:(NSBundle *)bundle {
    self.phase = @"checking";
    self.extractionStep = -1;
    [self emit:@"started" fields:@{@"bundleID":self.bundleID, @"currentVersion":self.originalVersion, @"oldPID":@(self.oldPID), @"cameraUsed":@NO}];
    self.updater = [[SPUUpdater alloc] initWithHostBundle:bundle applicationBundle:bundle userDriver:self delegate:self];
    NSError *error;
    if (![self.updater startUpdater:&error]) { [self fail:@"updater_start_failed" error:error]; return; }
    [self emit:@"updater_started" fields:@{}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self fail:@"driver_timeout" error:nil];
    });
    [self.updater checkForUpdates];
}
- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater { return self.feedURL.absoluteString; }
- (BOOL)updater:(SPUUpdater *)updater shouldDownloadReleaseNotesForUpdate:(SUAppcastItem *)item { return NO; }
- (NSSet<NSString *> *)allowedChannelsForUpdater:(SPUUpdater *)updater { return [NSSet setWithObject:@"beta"]; }
- (void)updater:(SPUUpdater *)updater didFinishLoadingAppcast:(SUAppcast *)appcast {
    self.feedVerified = appcast.signingValidationStatus == SPUAppcastSigningValidationStatusSucceeded;
    [self emit:@"feed_loaded" fields:@{@"feedSignatureStatus":@(appcast.signingValidationStatus), @"feedSignatureVerified":@(self.feedVerified)}];
    if (!self.feedVerified) [self fail:@"feed_signature_not_verified" error:nil];
}
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO automaticUpdateDownloading:@NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation {
    self.cancelPending = cancellation;
    [self emit:@"check_started" fields:@{}];
}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    NSURL *url = item.fileURL;
    BOOL accepted = !self.finished && self.feedVerified
        && item.signingValidationStatus == SPUAppcastSigningValidationStatusSucceeded
        && [item.versionString isEqualToString:self.expectedVersion]
        && state.stage == SPUUserUpdateStageNotDownloaded && state.userInitiated
        && LocalURL(url) && [url.port isEqual:self.feedURL.port]
        && [url.pathExtension.lowercaseString isEqualToString:@"zip"]
        && [item.installationType isEqualToString:@"application"]
        && item.contentLength > 0 && item.contentLength <= MaximumArchiveBytes
        && [self originalTargetIsRunning];
    [self emit:@"update_found" fields:@{@"version":item.versionString ?: @"", @"accepted":@(accepted), @"feedSignatureStatus":@(item.signingValidationStatus), @"stage":@(state.stage), @"archiveLength":@(item.contentLength)}];
    self.cancelPending = nil;
    reply(accepted ? SPUUserUpdateChoiceInstall : SPUUserUpdateChoiceSkip);
    if (!accepted) [self fail:@"update_item_rejected" error:nil];
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data { [self fail:@"unexpected_release_notes_download" error:nil]; }
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error { [self fail:@"unexpected_release_notes_download" error:error]; }
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    acknowledgement(); [self fail:@"expected_update_not_found" error:error];
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    acknowledgement(); [self fail:@"sparkle_error" error:error];
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation {
    self.phase = @"downloading"; self.cancelPending = cancellation;
    [self emit:@"download_started" fields:@{}];
}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {
    self.expectedBytes = length;
    [self emit:@"download_length" fields:@{@"expectedBytes":@(length)}];
    if (length > MaximumArchiveBytes) [self fail:@"archive_too_large" error:nil];
}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {
    if (length > MaximumArchiveBytes || self.receivedBytes > MaximumArchiveBytes - length) {
        [self fail:@"archive_too_large" error:nil]; return;
    }
    self.receivedBytes += length;
}
- (void)updater:(SPUUpdater *)updater didDownloadUpdate:(SUAppcastItem *)item {
    self.archiveDownloaded = YES; self.cancelPending = nil;
    [self emit:@"download_complete" fields:@{@"bytesDownloaded":@(self.receivedBytes)}];
}
- (void)showDownloadDidStartExtractingUpdate {
    self.phase = @"extracting"; self.cancelPending = nil;
    [self emit:@"extracting" fields:@{}];
}
- (void)showExtractionReceivedProgress:(double)progress {
    if (!isfinite(progress) || progress < 0 || progress > 1) return;
    NSInteger step = (NSInteger)(progress * 10);
    if (step > self.extractionStep) { self.extractionStep = step; [self emit:@"extraction_progress" fields:@{@"progress":@(progress)}]; }
}
- (void)updater:(SPUUpdater *)updater didExtractUpdate:(SUAppcastItem *)item {
    [self emit:@"extraction_complete" fields:@{}];
}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {
    BOOL accepted = !self.finished && self.archiveDownloaded && self.feedVerified && [self originalTargetIsRunning];
    [self emit:@"ready_to_install" fields:@{@"accepted":@(accepted)}];
    if (accepted) { self.phase = @"installing"; self.installStarted = YES; }
    reply(accepted ? SPUUserUpdateChoiceInstall : SPUUserUpdateChoiceSkip);
    if (!accepted) [self fail:@"installation_admission_rejected" error:nil];
}
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {
    [self emit:@"installing" fields:@{@"applicationTerminated":@(terminated)}];
}
- (BOOL)updaterShouldRelaunchApplication:(SPUUpdater *)updater { return !self.finished; }
- (void)updaterWillRelaunchApplication:(SPUUpdater *)updater { [self emit:@"will_relaunch" fields:@{}]; }
- (void)observeRelaunchedProcess {
    if (self.finished) return;
    // NSBundle caches the old Info dictionary; read the replaced plist directly.
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[self.hostPath stringByAppendingPathComponent:@"Contents/Info.plist"]];
    NSArray *targets = [self runningTargets];
    NSRunningApplication *target = targets.count == 1 ? targets.firstObject : nil;
    if ([info[@"CFBundleVersion"] isEqual:self.expectedVersion] && [info[@"CFBundleIdentifier"] isEqual:self.bundleID]
        && target && target.processIdentifier != self.oldPID) {
        self.newPID = target.processIdentifier;
        self.phase = @"relaunch_observed";
        [self emit:@"relaunched_process" fields:@{@"newPID":@(self.newPID), @"version":info[@"CFBundleVersion"]}];
        [self finish:YES reason:@"installed_and_relaunched"]; return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self observeRelaunchedProcess]; });
}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement {
    self.installationPerformed = YES; self.relaunched = relaunched; self.phase = @"installation_complete";
    [self emit:@"installation_complete" fields:@{@"relaunched":@(relaunched)}];
    acknowledgement();
    if (!relaunched || !self.installStarted || !self.archiveDownloaded || !self.feedVerified) {
        [self fail:@"installation_evidence_incomplete" error:nil]; return;
    }
    [self observeRelaunchedProcess];
}
- (void)dismissUpdateInstallation { [self emit:@"installation_dismissed" fields:@{}]; }
- (void)updater:(SPUUpdater *)updater didAbortWithError:(NSError *)error { [self fail:@"update_aborted" error:error]; }
- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)check error:(NSError *)error {
    [self emit:@"update_cycle_finished" fields:@{@"check":@(check), @"errorDomain":error.domain ?: @"", @"errorCode":@(error.code)}];
    if (error) [self fail:@"update_cycle_failed" error:error];
    // A successful check cycle alone is never installation evidence.
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableDictionary *args = [NSMutableDictionary dictionary];
        NSSet *allowed = [NSSet setWithArray:@[@"--host", @"--events", @"--expected-version", @"--workspace"]];
        for (int i = 1; i < argc; i += 2) {
            NSString *key = @(argv[i]);
            if (i + 1 >= argc || ![allowed containsObject:key] || args[key]) { fputs("Invalid fixture arguments\n", stderr); return 2; }
            args[key] = @(argv[i + 1]);
        }
        NSString *workspace = args[@"--workspace"], *host = args[@"--host"], *events = args[@"--events"], *version = args[@"--expected-version"];
        if (args.count != 4 || !workspace.isAbsolutePath || !host.isAbsolutePath || !events.isAbsolutePath
            || !PrivateDirectory(workspace) || !Inside(host, workspace) || !Inside(events, workspace)
            || Inside(events, host) || ![host.pathExtension isEqualToString:@"app"]
            || !OwnedDirectory(host) || !OwnedDirectory(events.stringByDeletingLastPathComponent)) {
            fputs("Only an owned private fixture workspace is accepted\n", stderr); return 2;
        }
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[host stringByAppendingPathComponent:@"Contents/Info.plist"]];
        NSString *identifier = info[@"CFBundleIdentifier"], *oldVersion = info[@"CFBundleVersion"];
        NSURL *feed = [NSURL URLWithString:info[@"SUFeedURL"] ?: @""];
        NSRegularExpression *identityPattern = [NSRegularExpression regularExpressionWithPattern:@"^studio\\.yuhuan\\.Pocket3Bridge\\.UpdateFixture\\.install\\.[0-9a-fA-F]{32}$" options:0 error:NULL];
        NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
        BOOL validIdentity = [identifier isKindOfClass:NSString.class]
            && [identityPattern numberOfMatchesInString:identifier options:0 range:NSMakeRange(0, identifier.length)] == 1;
        if (!validIdentity || ![oldVersion isKindOfClass:NSString.class] || version.length == 0 || oldVersion.length == 0
            || [version rangeOfCharacterFromSet:nonDigits].location != NSNotFound
            || [oldVersion rangeOfCharacterFromSet:nonDigits].location != NSNotFound
            || [version compare:oldVersion options:NSNumericSearch] != NSOrderedDescending
            || !LocalURL(feed) || ![info[@"SURequireSignedFeed"] isEqual:@YES]
            || ![info[@"SUVerifyUpdateBeforeExtraction"] isEqual:@YES]
            || ![info[@"SUEnableAutomaticChecks"] isEqual:@NO]
            || ![info[@"SUAutomaticallyUpdate"] isEqual:@NO]
            || ![info[@"SUAllowsAutomaticUpdates"] isEqual:@NO]
            || [[NSData alloc] initWithBase64EncodedString:info[@"SUPublicEDKey"] ?: @"" options:0].length != 32
            || ![info[@"CFBundleExecutable"] isEqualToString:@"Pocket3MCP"]
            || !RegularFile([host stringByAppendingPathComponent:@"Contents/Info.plist"])
            || !RegularFile([host stringByAppendingPathComponent:@"Contents/MacOS/Pocket3MCP"])) {
            fputs("Fixture identity, signed loopback feed, version, or automatic-update guard rejected\n", stderr); return 2;
        }
        // Sparkle framework contains relative symlinks. Keep those, reject escapes.
        NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:host];
        for (NSString *relative in enumerator) {
            if (!Inside([host stringByAppendingPathComponent:relative], host)) { fputs("Fixture contains a path escaping its bundle\n", stderr); return 2; }
        }
        InstallDriver *driver = [InstallDriver new];
        driver.hostPath = Canonical(host); driver.bundleID = identifier; driver.expectedVersion = version;
        driver.originalVersion = oldVersion; driver.feedURL = feed;
        NSArray *targets = [driver runningTargets];
        if (targets.count != 1 || [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier].count != 1) {
            fputs("Exactly one running App at the fixture path is required\n", stderr); return 2;
        }
        driver.oldPID = ((NSRunningApplication *)targets.firstObject).processIdentifier;
        driver.eventsFD = open(events.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (driver.eventsFD < 0) { fputs("Cannot exclusively create fixture event log\n", stderr); return 2; }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        dispatch_async(dispatch_get_main_queue(), ^{ [driver startWithBundle:[NSBundle bundleWithPath:host]]; });
        [NSApp run];
        return 1;
    }
}
