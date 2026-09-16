#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <unistd.h>

#import "airlift_target.h"

typedef const void *AMDeviceRef;
typedef const void *AMDeviceNotificationRef;
typedef void *AMDServiceConnectionRef;
typedef void *AFCConnectionRef;
typedef void *AFCKeyValueRef;
typedef void *AFCFileRef;
typedef void *AFCDirectoryRef;

typedef struct {
    AMDeviceRef device;
    unsigned int message;
} AMDeviceNotificationCallbackInfo;

extern int AMDeviceNotificationSubscribeWithOptions(
    void (*callback)(AMDeviceNotificationCallbackInfo *, void *),
    int unused,
    unsigned int connectionType,
    void *context,
    AMDeviceNotificationRef *subscription,
    CFDictionaryRef options);
extern int AMDeviceNotificationUnsubscribe(AMDeviceNotificationRef subscription);
extern CFStringRef AMDeviceCopyDeviceIdentifier(AMDeviceRef device);
extern CFTypeRef AMDeviceCopyValue(AMDeviceRef device,
                                   CFStringRef domain,
                                   CFStringRef key);
extern int AMDeviceConnect(AMDeviceRef device);
extern int AMDeviceDisconnect(AMDeviceRef device);
extern int AMDeviceIsPaired(AMDeviceRef device);
extern int AMDeviceValidatePairing(AMDeviceRef device);
extern int AMDeviceStartSession(AMDeviceRef device);
extern int AMDeviceStopSession(AMDeviceRef device);
extern int AMDeviceSecureStartService(AMDeviceRef device,
                                      CFStringRef serviceName,
                                      CFDictionaryRef options,
                                      AMDServiceConnectionRef *connection);
extern int AMDServiceConnectionGetSocket(AMDServiceConnectionRef connection);
extern void *AMDServiceConnectionGetSecureIOContext(
    AMDServiceConnectionRef connection);
extern int AMDServiceConnectionInvalidate(AMDServiceConnectionRef connection);
extern int AMDServiceConnectionSend(AMDServiceConnectionRef connection,
                                    const void *bytes,
                                    size_t length);
extern int AMDServiceConnectionSendMessage(AMDServiceConnectionRef connection,
                                           CFTypeRef message,
                                           CFPropertyListFormat format);
extern int AMDServiceConnectionReceiveMessage(AMDServiceConnectionRef connection,
                                              CFTypeRef *message,
                                              CFPropertyListFormat *format);

extern int AFCConnectionOpen(int socket,
                             unsigned int ioTimeout,
                             AFCConnectionRef *connection);
extern int AFCConnectionClose(AFCConnectionRef connection);
extern int AFCConnectionSetSecureContext(AFCConnectionRef connection,
                                         void *secureContext);
extern int AFCConnectionSetDisposeSecureContextOnInvalidate(
    AFCConnectionRef connection,
    int dispose);
extern int AFCConnectionSetIOTimeout(AFCConnectionRef connection,
                                     unsigned int timeout);
extern int AFCFileInfoOpen(AFCConnectionRef connection,
                           const char *path,
                           AFCKeyValueRef *dictionary);
extern int AFCKeyValueRead(AFCKeyValueRef dictionary, char **key, char **value);
extern int AFCKeyValueClose(AFCKeyValueRef dictionary);
extern int AFCFileRefOpen(AFCConnectionRef connection,
                          const char *path,
                          unsigned long long mode,
                          AFCFileRef *file);
extern int AFCFileRefRead(AFCConnectionRef connection,
                          AFCFileRef file,
                          void *bytes,
                          long *length);
extern int AFCFileRefWrite(AFCConnectionRef connection,
                           AFCFileRef file,
                           const void *bytes,
                           long length);
extern int AFCFileRefClose(AFCConnectionRef connection, AFCFileRef file);
extern int AFCDirectoryOpen(AFCConnectionRef connection,
                            const char *path,
                            AFCDirectoryRef *directory);
extern int AFCDirectoryRead(AFCConnectionRef connection,
                            AFCDirectoryRef directory,
                            char **entry);
extern int AFCDirectoryClose(AFCConnectionRef connection,
                             AFCDirectoryRef directory);
extern int AFCDirectoryCreate(AFCConnectionRef connection, const char *path);
extern int AFCRemovePath(AFCConnectionRef connection, const char *path);

static const char *TrackedBooksFiles[] = {
    "Books/Books.plist",
    "Books/Sync/Books.plist",
    "Books/Sync/Upload.plist",
    "Books/Sync/Database/OutstandingAssets_4.sqlite",
    "Books/Sync/Database/OutstandingAssets_4.sqlite-shm",
    "Books/Sync/Database/OutstandingAssets_4.sqlite-wal",
};

static const char *TrackedBooksDirectories[] = {
    "Books",
    "Books/Sync",
    "Books/Sync/Database",
};

static CFStringRef TargetIdentifier;
static AMDeviceRef TargetDevice;

typedef struct {
    AMDeviceRef device;
    BOOL connected;
    BOOL sessionStarted;
    AMDServiceConnectionRef afcService;
    AFCConnectionRef afc;
    int subscribeStatus;
    int connectStatus;
    int validateStatus;
    int sessionStatus;
    int serviceStatus;
    int afcStatus;
} DeviceSession;

static void DeviceCallback(AMDeviceNotificationCallbackInfo *info,
                           void *context) {
    (void)context;
    if (!info || !info->device || info->message != 1 || TargetDevice) return;
    CFStringRef identifier = AMDeviceCopyDeviceIdentifier(info->device);
    BOOL matches = identifier && CFEqual(identifier, TargetIdentifier);
    if (identifier) CFRelease(identifier);
    if (!matches) return;
    TargetDevice = CFRetain(info->device);
    CFRunLoopStop(CFRunLoopGetMain());
}

static int FindTarget(void) {
    NSDictionary *options = @{
        @"NotificationOptionSearchForPairedDevices": @YES,
        @"NotificationOptionSearchForPairedDevicesViaDirectConnectionsOnly": @NO,
        @"NotificationOptionSearchForWiFiPairableDevices": @NO,
        @"NotificationOptionEnableRemoteXPC": @YES,
        @"NotificationOptionEnableUSBMux": @YES,
    };
    AMDeviceNotificationRef subscription = NULL;
    int status = AMDeviceNotificationSubscribeWithOptions(
        DeviceCallback,
        0,
        0,
        NULL,
        &subscription,
        (__bridge CFDictionaryRef)options);
    if (status == 0)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 30.0, false);
    if (subscription) AMDeviceNotificationUnsubscribe(subscription);
    return status;
}

static void OpenSession(DeviceSession *session) {
    memset(session, 0, sizeof(*session));
    session->connectStatus = session->validateStatus = -1;
    session->sessionStatus = session->serviceStatus = session->afcStatus = -1;
    session->subscribeStatus = FindTarget();
    session->device = TargetDevice;
    if (!session->device) return;

    session->connectStatus = AMDeviceConnect(session->device);
    session->connected = session->connectStatus == 0;
    if (!session->connected || !AMDeviceIsPaired(session->device)) return;
    session->validateStatus = AMDeviceValidatePairing(session->device);
    if (session->validateStatus != 0) return;
    session->sessionStatus = AMDeviceStartSession(session->device);
    session->sessionStarted = session->sessionStatus == 0;
    if (!session->sessionStarted) return;
    session->serviceStatus = AMDeviceSecureStartService(
        session->device,
        CFSTR("com.apple.afc"),
        NULL,
        &session->afcService);
    if (session->serviceStatus != 0 || !session->afcService) return;
    session->afcStatus = AFCConnectionOpen(
        AMDServiceConnectionGetSocket(session->afcService),
        0,
        &session->afc);
    void *secureContext =
        AMDServiceConnectionGetSecureIOContext(session->afcService);
    if (session->afcStatus == 0 && session->afc && secureContext) {
        AFCConnectionSetSecureContext(session->afc, secureContext);
        AFCConnectionSetDisposeSecureContextOnInvalidate(session->afc, 0);
        AFCConnectionSetIOTimeout(session->afc, 30);
    }
}

static void CloseSession(DeviceSession *session) {
    if (session->afc) AFCConnectionClose(session->afc);
    if (session->afcService)
        AMDServiceConnectionInvalidate(session->afcService);
    if (session->sessionStarted) AMDeviceStopSession(session->device);
    if (session->connected) AMDeviceDisconnect(session->device);
    if (session->device) CFRelease(session->device);
    TargetDevice = NULL;
}

static void PrintJSON(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:0
                                                     error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fwrite("\n", 1, 1, stdout);
}

static BOOL AFCExists(AFCConnectionRef afc, NSString *path) {
    AFCKeyValueRef info = NULL;
    int status = AFCFileInfoOpen(afc, path.fileSystemRepresentation, &info);
    if (info) AFCKeyValueClose(info);
    return status == 0;
}

static long long AFCFileSize(AFCConnectionRef afc, NSString *path) {
    AFCKeyValueRef info = NULL;
    if (AFCFileInfoOpen(afc, path.fileSystemRepresentation, &info) != 0 ||
        !info) return -1;
    long long size = -1;
    char *key = NULL;
    char *value = NULL;
    while (AFCKeyValueRead(info, &key, &value) == 0 && key && value) {
        if (strcmp(key, "st_size") == 0) size = strtoll(value, NULL, 10);
        key = NULL;
        value = NULL;
    }
    AFCKeyValueClose(info);
    return size;
}

static NSString *AFCFileKind(AFCConnectionRef afc, NSString *path) {
    AFCKeyValueRef info = NULL;
    if (AFCFileInfoOpen(afc, path.fileSystemRepresentation, &info) != 0 ||
        !info) return nil;
    NSString *kind = nil;
    char *key = NULL;
    char *value = NULL;
    while (AFCKeyValueRead(info, &key, &value) == 0 && key && value) {
        if (strcmp(key, "st_ifmt") == 0)
            kind = [NSString stringWithUTF8String:value];
        key = NULL;
        value = NULL;
    }
    AFCKeyValueClose(info);
    return kind;
}

static NSData *AFCReadFileWithLimit(AFCConnectionRef afc,
                                    NSString *path,
                                    long long limit) {
    long long size = AFCFileSize(afc, path);
    if (size < 0 || size > limit) return nil;
    AFCFileRef file = NULL;
    if (AFCFileRefOpen(afc, path.fileSystemRepresentation, 1, &file) != 0 ||
        !file) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)size];
    long long offset = 0;
    int status = 0;
    while (offset < size) {
        long length = (long)(size - offset);
        status = AFCFileRefRead(
            afc, file, (uint8_t *)data.mutableBytes + offset, &length);
        if (status != 0 || length <= 0 || length > size - offset) break;
        offset += length;
    }
    int closeStatus = AFCFileRefClose(afc, file);
    if (status != 0 || closeStatus != 0 || offset != size) return nil;
    return data;
}

static NSData *AFCReadFile(AFCConnectionRef afc, NSString *path) {
    return AFCReadFileWithLimit(afc, path, 16 * 1024 * 1024);
}

static BOOL AFCWriteFile(AFCConnectionRef afc, NSString *path, NSData *data) {
    AFCFileRef file = NULL;
    int status = AFCFileRefOpen(afc, path.fileSystemRepresentation, 3, &file);
    if (status != 0 || !file) return NO;
    status = data.length == 0
        ? 0 : AFCFileRefWrite(afc, file, data.bytes, (long)data.length);
    int closeStatus = AFCFileRefClose(afc, file);
    return status == 0 && closeStatus == 0;
}

static BOOL EnsureDirectory(AFCConnectionRef afc, NSString *path) {
    return AFCExists(afc, path) ||
        AFCDirectoryCreate(afc, path.fileSystemRepresentation) == 0;
}

static BOOL RemoveIfPresent(AFCConnectionRef afc, NSString *path) {
    if (!AFCExists(afc, path)) return YES;
    return AFCRemovePath(afc, path.fileSystemRepresentation) == 0 &&
        !AFCExists(afc, path);
}

static BOOL AllTrackedBooksFilesAbsent(AFCConnectionRef afc) {
    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksFiles) / sizeof(char *);
         index++) {
        NSString *path =
            [NSString stringWithUTF8String:TrackedBooksFiles[index]];
        if (AFCExists(afc, path)) return NO;
    }
    return YES;
}

static NSArray<NSString *> *PresentTrackedBooksPaths(AFCConnectionRef afc) {
    NSMutableArray<NSString *> *paths = NSMutableArray.array;
    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksFiles) / sizeof(char *);
         index++) {
        NSString *path =
            [NSString stringWithUTF8String:TrackedBooksFiles[index]];
        if (AFCExists(afc, path)) [paths addObject:path];
    }
    return paths;
}

static NSString *SnapshotFileName(NSUInteger index) {
    return [NSString stringWithFormat:@"file-%lu.bin", (unsigned long)index];
}

static NSString *SnapshotManifestPath(NSString *root) {
    return [root stringByAppendingPathComponent:@"manifest.plist"];
}

static NSDictionary *LoadBooksSnapshot(NSString *root) {
    NSData *data = [NSData dataWithContentsOfFile:SnapshotManifestPath(root)];
    if (!data) return nil;
    id value = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:NULL error:nil];
    if (![value isKindOfClass:NSDictionary.class] ||
        ![value[@"version"] isEqual:@1] ||
        ![value[@"files"] isKindOfClass:NSDictionary.class] ||
        ![value[@"directories"] isKindOfClass:NSDictionary.class]) return nil;

    NSDictionary *files = value[@"files"];
    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksFiles) / sizeof(char *);
         index++) {
        NSString *path = [NSString stringWithUTF8String:TrackedBooksFiles[index]];
        NSDictionary *row = [files[path] isKindOfClass:NSDictionary.class]
            ? files[path] : nil;
        NSString *expectedName = SnapshotFileName(index);
        if (![row[@"exists"] isKindOfClass:NSNumber.class] ||
            ![row[@"localName"] isEqual:expectedName]) return nil;
        if ([row[@"exists"] boolValue]) {
            NSString *localPath = [root stringByAppendingPathComponent:expectedName];
            BOOL isDirectory = NO;
            if (![[NSFileManager defaultManager] fileExistsAtPath:localPath
                isDirectory:&isDirectory] || isDirectory) return nil;
        }
    }
    NSDictionary *directories = value[@"directories"];
    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksDirectories) / sizeof(char *);
         index++) {
        NSString *path =
            [NSString stringWithUTF8String:TrackedBooksDirectories[index]];
        if (![directories[path] isKindOfClass:NSNumber.class]) return nil;
    }
    return value;
}

static NSDictionary *SnapshotBooksState(AFCConnectionRef afc, NSString *root) {
    BOOL isDirectory = NO;
    BOOL rootReady = [[NSFileManager defaultManager] fileExistsAtPath:root
        isDirectory:&isDirectory] && isDirectory;
    if (!rootReady ||
        [[NSFileManager defaultManager] fileExistsAtPath:SnapshotManifestPath(root)])
        return @{ @"ok": @NO, @"snapshotDirectoryReady": @(rootReady) };

    NSMutableDictionary *files = NSMutableDictionary.dictionary;
    NSMutableDictionary *directories = NSMutableDictionary.dictionary;
    NSMutableArray<NSString *> *presentPaths = NSMutableArray.array;
    unsigned long long totalBytes = 0;
    NSError *localError = nil;

    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksFiles) / sizeof(char *);
         index++) {
        NSString *path = [NSString stringWithUTF8String:TrackedBooksFiles[index]];
        NSString *localName = SnapshotFileName(index);
        BOOL exists = AFCExists(afc, path);
        if (exists && ![AFCFileKind(afc, path) isEqual:@"S_IFREG"])
            return @{ @"ok": @NO, @"unexpectedFileType": path };
        NSData *data = exists
            ? AFCReadFileWithLimit(afc, path, 128 * 1024 * 1024) : nil;
        if (exists && !data)
            return @{ @"ok": @NO, @"snapshotReadFailed": path };
        if (data) {
            totalBytes += data.length;
            if (totalBytes > 256 * 1024 * 1024)
                return @{ @"ok": @NO, @"snapshotTooLarge": @YES };
            NSString *localPath = [root stringByAppendingPathComponent:localName];
            if (![data writeToFile:localPath
                    options:NSDataWritingWithoutOverwriting
                      error:&localError])
                return @{ @"ok": @NO,
                          @"snapshotWriteFailed": path,
                          @"localError": localError.localizedDescription ?: @"unknown" };
            [presentPaths addObject:path];
        }
        files[path] = @{ @"exists": @(exists),
                         @"localName": localName,
                         @"size": @(data.length) };
    }

    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksDirectories) / sizeof(char *);
         index++) {
        NSString *path =
            [NSString stringWithUTF8String:TrackedBooksDirectories[index]];
        BOOL exists = AFCExists(afc, path);
        NSString *kind = exists ? AFCFileKind(afc, path) : nil;
        if (exists && ![kind isEqual:@"S_IFDIR"])
            return @{ @"ok": @NO, @"unexpectedDirectoryType": path };
        directories[path] = @(exists);
    }

    NSDictionary *manifest = @{ @"version": @1,
                                 @"files": files,
                                 @"directories": directories };
    NSData *manifestData = [NSPropertyListSerialization
        dataWithPropertyList:manifest format:NSPropertyListBinaryFormat_v1_0
        options:0 error:&localError];
    BOOL wroteManifest = manifestData && [manifestData
        writeToFile:SnapshotManifestPath(root)
        options:NSDataWritingAtomic
        error:&localError];
    return @{ @"ok": @(wroteManifest),
              @"presentPaths": presentPaths,
              @"snapshotBytes": @(totalBytes),
              @"localError": wroteManifest
                  ? (id)NSNull.null
                  : (localError.localizedDescription ?: @"unknown") };
}

static BOOL BooksStateMatchesSnapshot(AFCConnectionRef afc,
                                      NSString *root,
                                      NSDictionary *snapshot) {
    NSDictionary *files = snapshot[@"files"];
    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksFiles) / sizeof(char *);
         index++) {
        NSString *path = [NSString stringWithUTF8String:TrackedBooksFiles[index]];
        NSDictionary *row = files[path];
        BOOL expectedExists = [row[@"exists"] boolValue];
        if (AFCExists(afc, path) != expectedExists) return NO;
        if (expectedExists) {
            NSData *expected = [NSData dataWithContentsOfFile:
                [root stringByAppendingPathComponent:SnapshotFileName(index)]];
            NSData *observed =
                AFCReadFileWithLimit(afc, path, 128 * 1024 * 1024);
            if (!expected || !observed || ![observed isEqualToData:expected])
                return NO;
        }
    }

    NSDictionary *directories = snapshot[@"directories"];
    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksDirectories) / sizeof(char *);
         index++) {
        NSString *path =
            [NSString stringWithUTF8String:TrackedBooksDirectories[index]];
        BOOL expectedExists = [directories[path] boolValue];
        BOOL exists = AFCExists(afc, path);
        if (exists != expectedExists) return NO;
        if (exists && ![AFCFileKind(afc, path) isEqual:@"S_IFDIR"])
            return NO;
    }
    return YES;
}

static BOOL EnsureBooksParent(AFCConnectionRef afc, NSString *path) {
    if (!EnsureDirectory(afc, @"Books")) return NO;
    if ([path hasPrefix:@"Books/Sync/"] &&
        !EnsureDirectory(afc, @"Books/Sync")) return NO;
    if ([path hasPrefix:@"Books/Sync/Database/"] &&
        !EnsureDirectory(afc, @"Books/Sync/Database")) return NO;
    return YES;
}

static NSDictionary *RestoreBooksState(AFCConnectionRef afc, NSString *root) {
    NSDictionary *snapshot = LoadBooksSnapshot(root);
    if (!snapshot) return @{ @"ok": @NO, @"error": @"invalid snapshot" };
    NSMutableArray<NSString *> *failures = NSMutableArray.array;
    NSDictionary *files = snapshot[@"files"];

    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksFiles) / sizeof(char *);
         index++) {
        NSString *path = [NSString stringWithUTF8String:TrackedBooksFiles[index]];
        NSDictionary *row = files[path];
        if ([row[@"exists"] boolValue]) {
            NSData *data = [NSData dataWithContentsOfFile:
                [root stringByAppendingPathComponent:SnapshotFileName(index)]];
            if (!data || !EnsureBooksParent(afc, path) ||
                !AFCWriteFile(afc, path, data)) [failures addObject:path];
        } else if (!RemoveIfPresent(afc, path)) {
            [failures addObject:path];
        }
    }

    NSDictionary *directories = snapshot[@"directories"];
    for (NSInteger index =
             (NSInteger)(sizeof(TrackedBooksDirectories) / sizeof(char *)) - 1;
         index >= 0; index--) {
        NSString *path =
            [NSString stringWithUTF8String:TrackedBooksDirectories[index]];
        if (![directories[path] boolValue] && !RemoveIfPresent(afc, path))
            [failures addObject:path];
    }
    BOOL verified = failures.count == 0 &&
        BooksStateMatchesSnapshot(afc, root, snapshot);
    return @{ @"ok": @(verified),
              @"failures": failures,
              @"preimageVerified": @(verified) };
}

static BOOL IsSafeRelativePath(NSString *path) {
    if (!path.length || [path hasPrefix:@"/"] || [path hasSuffix:@"/"])
        return NO;
    for (NSString *component in [path componentsSeparatedByString:@"/"])
        if (!component.length || [component isEqual:@"."] ||
            [component isEqual:@".."]) return NO;
    return YES;
}

static BOOL IsLowercaseHex(NSString *value, NSUInteger length) {
    if (value.length != length) return NO;
    for (NSUInteger index = 0; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];
        if (!((character >= '0' && character <= '9') ||
              (character >= 'a' && character <= 'f'))) return NO;
    }
    return YES;
}

static NSString *GeneratedToken(NSString *value, NSString *prefix) {
    if (![value hasPrefix:prefix] ||
        [value rangeOfString:@"/"].location != NSNotFound) return nil;
    NSString *token = [value substringFromIndex:prefix.length];
    return IsLowercaseHex(token, 20) ? token : nil;
}

static BOOL GeneratedNameMatchesToken(NSString *value,
                                      NSString *prefix,
                                      NSString *token) {
    return token && [[GeneratedToken(value, prefix) lowercaseString]
        isEqualToString:token];
}

static BOOL GeneratedNamesMatch(NSString *source,
                                NSString *linkDestination,
                                NSString *recovered) {
    NSString *token = GeneratedToken(source, AIRLIFT_SOURCE_PREFIX);
    return GeneratedNameMatchesToken(
               linkDestination, AIRLIFT_LINK_PREFIX, token) &&
        GeneratedNameMatchesToken(
               recovered, AIRLIFT_RECOVERED_PREFIX, token);
}

static BOOL GeneratedSetMatches(NSString *source,
                                NSString *linkDestination,
                                NSString *recovered,
                                NSString *backup) {
    NSString *token = GeneratedToken(source, AIRLIFT_SOURCE_PREFIX);
    BOOL backupMatches = [backup isEqual:@"-"] ||
        GeneratedNameMatchesToken(backup, AIRLIFT_BACKUP_PREFIX, token);
    return GeneratedNameMatchesToken(
               linkDestination, AIRLIFT_LINK_PREFIX, token) &&
        GeneratedNameMatchesToken(
               recovered, AIRLIFT_RECOVERED_PREFIX, token) && backupMatches;
}

static BOOL IsPullableGeneratedName(NSString *name) {
    return GeneratedToken(name, AIRLIFT_RECOVERED_PREFIX) ||
        GeneratedToken(name, AIRLIFT_BACKUP_PREFIX);
}

typedef struct {
    NSUInteger files;
    NSUInteger directories;
    unsigned long long bytes;
} PullCounters;

static BOOL SafeAFCChildName(NSString *name) {
    return name.length && ![name isEqual:@"."] && ![name isEqual:@".."] &&
        [name rangeOfString:@"/"].location == NSNotFound &&
        [name rangeOfString:@"\0"].location == NSNotFound;
}

static NSSet<NSString *> *PaymentCardIDs(AFCConnectionRef afc,
                                        NSString *cardsRoot) {
    AFCDirectoryRef directory = NULL;
    if (AFCDirectoryOpen(afc, cardsRoot.fileSystemRepresentation, &directory) !=
            0 || !directory) return nil;
    NSMutableArray<NSString *> *children = NSMutableArray.array;
    BOOL readOK = YES;
    for (NSUInteger index = 0; index < 20000; index++) {
        char *raw = NULL;
        if (AFCDirectoryRead(afc, directory, &raw) != 0) {
            readOK = NO;
            break;
        }
        if (!raw) break;
        NSString *name = [NSString stringWithUTF8String:raw];
        if (!name || [name isEqual:@"."] || [name isEqual:@".."]) continue;
        if (!SafeAFCChildName(name)) {
            readOK = NO;
            break;
        }
        [children addObject:name];
    }
    BOOL closeOK = AFCDirectoryClose(afc, directory) == 0;
    if (!readOK || !closeOK) return nil;

    NSMutableSet<NSString *> *identifiers = NSMutableSet.set;
    for (NSString *name in children) {
        if (![name hasSuffix:@".pkpass"]) continue;
        NSString *passJSON = [[cardsRoot stringByAppendingPathComponent:name]
            stringByAppendingPathComponent:@"pass.json"];
        NSData *data = AFCReadFileWithLimit(afc, passJSON, 4 * 1024 * 1024);
        if (!data) continue;
        id value = [NSJSONSerialization JSONObjectWithData:data
                                                   options:0
                                                     error:nil];
        if (![value isKindOfClass:NSDictionary.class] ||
            ![(NSDictionary *)value objectForKey:@"paymentCard"]) continue;
        [identifiers addObject:[name substringToIndex:
            name.length - @".pkpass".length]];
    }
    return identifiers;
}

static NSString *CardIDFromContainer(NSString *container) {
    for (NSString *suffix in @[ @".cache", @".pkpass" ]) {
        if ([container hasSuffix:suffix] && container.length > suffix.length)
            return [container substringToIndex:container.length - suffix.length];
    }
    return nil;
}

static BOOL IsCardCatalogFile(NSString *relativePath,
                              NSSet<NSString *> *paymentCardIDs) {
    NSArray<NSString *> *components = relativePath.pathComponents;
    if (components.count != 2) return NO;
    NSString *container = components[0];
    NSString *file = components[1];
    NSString *cardID = CardIDFromContainer(container);
    if (!cardID || ![paymentCardIDs containsObject:cardID]) return NO;
    if ([container hasSuffix:@".cache"])
        return [file isEqual:@"FrontFace"];
    if (![container hasSuffix:@".pkpass"]) return NO;
    return [file isEqual:@"pass.json"] ||
        [file isEqual:@"cardBackgroundCombined.pdf"] ||
        [file isEqual:@"cardBackgroundCombined.png"] ||
        [file isEqual:@"cardBackgroundCombined@2x.png"] ||
        [file isEqual:@"cardBackgroundCombined@3x.png"];
}

static BOOL IsCardCatalogDirectory(NSString *relativePath,
                                   NSSet<NSString *> *paymentCardIDs) {
    if (!relativePath.length) return YES;
    NSArray<NSString *> *components = relativePath.pathComponents;
    if (components.count != 1) return NO;
    NSString *cardID = CardIDFromContainer(components[0]);
    return cardID && [paymentCardIDs containsObject:cardID];
}

static BOOL PullAFCPath(AFCConnectionRef afc,
                       NSString *remotePath,
                       NSString *localPath,
                       NSString *relativePath,
                       BOOL catalogOnly,
                       NSSet<NSString *> *paymentCardIDs,
                       NSUInteger depth,
                       PullCounters *counters,
                       NSString **failure) {
    if (depth > 48 || counters->files + counters->directories > 20000) {
        *failure = @"directory limit exceeded";
        return NO;
    }
    NSString *kind = AFCFileKind(afc, remotePath);
    if ([kind isEqual:@"S_IFREG"]) {
        if (catalogOnly &&
            !IsCardCatalogFile(relativePath, paymentCardIDs)) return YES;
        NSData *data = AFCReadFileWithLimit(afc, remotePath, 128 * 1024 * 1024);
        if (!data || counters->bytes + data.length > 512ULL * 1024 * 1024) {
            *failure = @"file read or size limit failed";
            return NO;
        }
        NSError *error = nil;
        if (![data writeToFile:localPath
                       options:NSDataWritingWithoutOverwriting
                         error:&error]) {
            *failure = error.localizedDescription ?: @"local write failed";
            return NO;
        }
        counters->files++;
        counters->bytes += data.length;
        return YES;
    }
    if (![kind isEqual:@"S_IFDIR"]) {
        *failure = @"unsupported AFC entry type";
        return NO;
    }
    if (catalogOnly &&
        !IsCardCatalogDirectory(relativePath, paymentCardIDs)) return YES;

    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:localPath
                                  withIntermediateDirectories:NO
                                                   attributes:nil
                                                        error:&error]) {
        *failure = error.localizedDescription ?: @"local directory failed";
        return NO;
    }
    counters->directories++;
    AFCDirectoryRef directory = NULL;
    if (AFCDirectoryOpen(afc, remotePath.fileSystemRepresentation, &directory) !=
            0 || !directory) {
        *failure = @"AFC directory open failed";
        return NO;
    }
    NSMutableArray<NSString *> *children = NSMutableArray.array;
    BOOL readOK = YES;
    for (NSUInteger index = 0; index < 20000; index++) {
        char *raw = NULL;
        if (AFCDirectoryRead(afc, directory, &raw) != 0) {
            readOK = NO;
            break;
        }
        if (!raw) break;
        NSString *name = [NSString stringWithUTF8String:raw];
        if (!name || [name isEqual:@"."] || [name isEqual:@".."]) continue;
        if (!SafeAFCChildName(name)) {
            readOK = NO;
            *failure = @"unsafe AFC child name";
            break;
        }
        [children addObject:name];
    }
    BOOL closeOK = AFCDirectoryClose(afc, directory) == 0;
    if (!readOK || !closeOK) {
        if (!*failure) *failure = @"AFC directory read failed";
        return NO;
    }
    [children sortUsingSelector:@selector(compare:)];
    for (NSString *name in children) {
        if (!PullAFCPath(afc,
                        [remotePath stringByAppendingPathComponent:name],
                        [localPath stringByAppendingPathComponent:name],
                        relativePath.length
                            ? [relativePath stringByAppendingPathComponent:name]
                            : name,
                        catalogOnly,
                        paymentCardIDs,
                        depth + 1,
                        counters,
                        failure)) return NO;
    }
    return YES;
}

static NSDictionary *PullGenerated(AFCConnectionRef afc,
                                   NSString *remoteName,
                                   NSString *localPath,
                                   BOOL catalogOnly) {
    BOOL safe = IsPullableGeneratedName(remoteName);
    BOOL localAbsent = ![[NSFileManager defaultManager]
        fileExistsAtPath:localPath];
    BOOL remotePresent = NO;
    NSUInteger waitAttempts = 0;
    if (safe && localAbsent) {
        for (NSUInteger index = 0; index < 200; index++) {
            waitAttempts++;
            remotePresent = AFCExists(afc, remoteName);
            if (remotePresent) break;
            usleep(50000);
        }
    }
    if (!safe || !localAbsent || !remotePresent)
        return @{ @"ok": @NO,
                  @"safeName": @(safe),
                  @"localDestinationAbsent": @(localAbsent),
                  @"remotePresent": @(remotePresent),
                  @"waitAttempts": @(waitAttempts) };
    PullCounters counters = {0, 0, 0};
    NSString *failure = nil;
    NSSet<NSString *> *paymentCardIDs = catalogOnly
        ? PaymentCardIDs(afc, remoteName) : nil;
    if (catalogOnly && !paymentCardIDs)
        return @{ @"ok": @NO,
                  @"safeName": @YES,
                  @"localDestinationAbsent": @YES,
                  @"remotePresent": @YES,
                  @"paymentCardScanFailed": @YES,
                  @"waitAttempts": @(waitAttempts) };
    BOOL ok = PullAFCPath(
        afc,
        remoteName,
        localPath,
        @"",
        catalogOnly,
        paymentCardIDs,
        0,
        &counters,
        &failure);
    return @{ @"ok": @(ok),
              @"fileCount": @(counters.files),
              @"directoryCount": @(counters.directories),
              @"totalBytes": @(counters.bytes),
              @"paymentCardCount": @(paymentCardIDs.count),
              @"waitAttempts": @(waitAttempts),
              @"failure": failure ?: (id)NSNull.null };
}

static NSDictionary *GeneratedStatus(AFCConnectionRef afc,
                                     NSArray<NSString *> *args) {
    NSString *source = args[0];
    NSString *linkDestination = args[1];
    NSString *recovered = args[2];
    NSString *backup = args[3];
    BOOL safe = GeneratedSetMatches(
        source, linkDestination, recovered, backup);
    if (!safe) return @{ @"ok": @NO, @"safeArguments": @NO };
    NSString *recoveredKind = AFCFileKind(afc, recovered);
    return @{ @"ok": @YES,
              @"safeArguments": @YES,
              @"sourcePresent": @(AFCExists(afc, source)),
              @"linkPresent": @(AFCExists(afc, linkDestination)),
              @"payloadPresent": @(AFCExists(
                  afc, [source stringByAppendingPathComponent:@"payload"])),
              @"barrierPresent": @(AFCExists(
                  afc, [source stringByAppendingPathComponent:@"barrier"])),
              @"barrierDonePresent": @(AFCExists(
                  afc,
                  [source stringByAppendingPathComponent:@"barrier-done"])),
              @"recoveredPresent": @(AFCExists(afc, recovered)),
              @"recoveredKind": recoveredKind ?: (id)NSNull.null,
              @"backupPresent": @(![backup isEqual:@"-"] &&
                  AFCExists(afc, backup)) };
}

static NSDictionary *WaitGeneratedStatus(AFCConnectionRef afc,
                                         NSArray<NSString *> *args) {
    NSString *expectedRecovered = args[4];
    NSString *expectedBackup = args[5];
    BOOL validExpectations =
        ([expectedRecovered isEqual:@"0"] ||
         [expectedRecovered isEqual:@"1"]) &&
        ([expectedBackup isEqual:@"-"] ||
         [expectedBackup isEqual:@"0"] ||
         [expectedBackup isEqual:@"1"]);
    if (!validExpectations)
        return @{ @"ok": @NO, @"safeArguments": @NO };

    NSDictionary *status = nil;
    BOOL observed = NO;
    NSUInteger waitAttempts = 0;
    for (NSUInteger index = 0; index < 100; index++) {
        waitAttempts++;
        status = GeneratedStatus(afc, [args subarrayWithRange:NSMakeRange(0, 4)]);
        if (![status[@"ok"] boolValue]) return status;
        BOOL recoveredMatches =
            [status[@"recoveredPresent"] boolValue] ==
            [expectedRecovered isEqual:@"1"];
        BOOL backupMatches = [expectedBackup isEqual:@"-"] ||
            ([status[@"backupPresent"] boolValue] ==
             [expectedBackup isEqual:@"1"]);
        if (recoveredMatches && backupMatches) {
            observed = YES;
            break;
        }
        usleep(50000);
    }
    NSMutableDictionary *result = [status mutableCopy];
    result[@"stateObserved"] = @(observed);
    result[@"waitAttempts"] = @(waitAttempts);
    return result;
}

static BOOL RemoveGeneratedTree(AFCConnectionRef afc,
                                NSString *path,
                                NSUInteger depth);

static NSDictionary *CleanupGenerated(AFCConnectionRef afc,
                                      NSArray<NSString *> *args) {
    NSString *source = args[0];
    NSString *linkDestination = args[1];
    NSString *recovered = args[2];
    NSString *backup = args[3];
    NSString *snapshotRoot = args[4];
    BOOL safe = GeneratedSetMatches(
        source, linkDestination, recovered, backup);
    NSDictionary *snapshot = LoadBooksSnapshot(snapshotRoot);
    if (!safe || !snapshot)
        return @{ @"ok": @NO, @"safeArguments": @(safe) };
    NSMutableArray<NSString *> *failures = NSMutableArray.array;
    for (NSString *path in @[ linkDestination, recovered ])
        if (!RemoveGeneratedTree(afc, path, 0)) [failures addObject:path];
    if (![backup isEqual:@"-"] && !RemoveGeneratedTree(afc, backup, 0))
        [failures addObject:backup];
    if (!RemoveGeneratedTree(afc, source, 0)) [failures addObject:source];
    NSDictionary *booksRestore = RestoreBooksState(afc, snapshotRoot);
    if (![booksRestore[@"ok"] boolValue]) [failures addObject:@"Books preimage"];
    return @{ @"ok": @(failures.count == 0),
              @"failures": failures,
              @"booksPreimageRestored": @([booksRestore[@"ok"] boolValue]),
              @"booksRestore": booksRestore };
}

static BOOL IsCanaryLeaf(NSString *leaf) {
    if (![leaf hasPrefix:AIRLIFT_CANARY_PREFIX] ||
        ![leaf hasSuffix:@".bin"] ||
        leaf.length < AIRLIFT_CANARY_PREFIX.length + @".bin".length ||
        [leaf rangeOfString:@"/"].location != NSNotFound) return NO;
    NSRange tokenRange = NSMakeRange(
        AIRLIFT_CANARY_PREFIX.length,
        leaf.length - AIRLIFT_CANARY_PREFIX.length - @".bin".length);
    return IsLowercaseHex([leaf substringWithRange:tokenRange], 32);
}

static BOOL RemoveGeneratedTree(AFCConnectionRef afc,
                                NSString *path,
                                NSUInteger depth) {
    if (depth > 32) return NO;
    NSString *kind = AFCFileKind(afc, path);
    if (!kind) return YES;
    if ([kind isEqual:@"S_IFDIR"]) {
        AFCDirectoryRef directory = NULL;
        if (AFCDirectoryOpen(afc, path.fileSystemRepresentation, &directory) !=
                0 ||
            !directory) return NO;
        NSMutableArray<NSString *> *children = NSMutableArray.array;
        BOOL readOK = YES;
        for (NSUInteger index = 0; index < 8192; index++) {
            char *raw = NULL;
            int status = AFCDirectoryRead(afc, directory, &raw);
            if (status != 0) {
                readOK = NO;
                break;
            }
            if (!raw) break;
            NSString *name = [NSString stringWithUTF8String:raw];
            if (!name || [name isEqual:@"."] || [name isEqual:@".."]) continue;
            [children addObject:name];
        }
        BOOL closeOK = AFCDirectoryClose(afc, directory) == 0;
        if (!readOK || !closeOK) return NO;
        for (NSString *name in children) {
            NSString *child = [path stringByAppendingPathComponent:name];
            if (!RemoveGeneratedTree(afc, child, depth + 1)) return NO;
        }
    }
    return AFCRemovePath(afc, path.fileSystemRepresentation) == 0 &&
        !AFCExists(afc, path);
}

static NSDictionary *SessionSummary(DeviceSession *session) {
    id productType = session->connected
        ? CFBridgingRelease(AMDeviceCopyValue(
              session->device, NULL, CFSTR("ProductType"))) : nil;
    id productVersion = session->connected
        ? CFBridgingRelease(AMDeviceCopyValue(
              session->device, NULL, CFSTR("ProductVersion"))) : nil;
    id buildVersion = session->connected
        ? CFBridgingRelease(AMDeviceCopyValue(
              session->device, NULL, CFSTR("BuildVersion"))) : nil;
    return @{
        @"subscribeStatus": @(session->subscribeStatus),
        @"targetObserved": @(session->device != NULL),
        @"connectStatus": @(session->connectStatus),
        @"validateStatus": @(session->validateStatus),
        @"sessionStatus": @(session->sessionStatus),
        @"serviceStatus": @(session->serviceStatus),
        @"afcStatus": @(session->afcStatus),
        @"productType": [productType isKindOfClass:NSString.class]
            ? productType : @"(nil)",
        @"productVersion": [productVersion isKindOfClass:NSString.class]
            ? productVersion : @"(nil)",
        @"buildVersion": [buildVersion isKindOfClass:NSString.class]
            ? buildVersion : @"(nil)",
    };
}

static BOOL BuildMatches(NSDictionary *summary,
                         NSString *version,
                         NSString *build) {
    return [summary[@"productVersion"] isEqual:version] &&
        [summary[@"buildVersion"] isEqual:build];
}

static BOOL TargetGate(NSDictionary *summary, BOOL *tested) {
    *tested = NO;
    if (![summary[@"productType"] hasPrefix:@"iPhone"]) return NO;
#define AIRLIFT_MATCH_TESTED(version, build) \
    if (BuildMatches(summary, version, build)) { \
        *tested = YES; \
        return YES; \
    }
    AIRLIFT_TESTED_BUILDS(AIRLIFT_MATCH_TESTED)
#undef AIRLIFT_MATCH_TESTED
    return YES;
}

static BOOL SendAll(AMDServiceConnectionRef service, NSData *data) {
    const uint8_t *cursor = data.bytes;
    size_t remaining = data.length;
    while (remaining) {
        int sent = AMDServiceConnectionSend(service, cursor, remaining);
        if (sent <= 0) return NO;
        cursor += sent;
        remaining -= (size_t)sent;
    }
    return YES;
}

static NSDictionary *Stage(DeviceSession *session, NSArray<NSString *> *args) {
    NSString *source = args[0];
    NSString *linkDestination = args[1];
    NSString *recovered = args[2];
    NSData *archive = [NSData dataWithContentsOfFile:args[3]];
    NSData *books = [NSData dataWithContentsOfFile:args[4]];
    NSString *snapshotRoot = args[5];
    NSDictionary *snapshot = LoadBooksSnapshot(snapshotRoot);
    BOOL safeArguments =
        GeneratedNamesMatch(source, linkDestination, recovered);
    BOOL snapshotMatches = snapshot && BooksStateMatchesSnapshot(
        session->afc, snapshotRoot, snapshot);
    BOOL freshPaths = !AFCExists(session->afc, source) &&
        !AFCExists(session->afc, linkDestination) &&
        !AFCExists(session->afc, recovered);
    if (!safeArguments || !archive || !books || !snapshotMatches || !freshPaths) {
        return @{ @"ok": @NO,
                  @"cleanupAuthorized": @NO,
                  @"safeArguments": @(safeArguments),
                  @"localInputsReadable": @(archive != nil && books != nil),
                  @"booksPreimageStable": @(snapshotMatches),
                  @"freshPaths": @(freshPaths) };
    }

    AMDServiceConnectionRef zipService = NULL;
    int serviceStatus = AMDeviceSecureStartService(
        session->device,
        CFSTR("com.apple.streaming_zip_conduit"),
        NULL,
        &zipService);
    int messageStatus = -1;
    int responseStatus = -1;
    BOOL archiveSent = NO;
    CFTypeRef response = NULL;
    if (serviceStatus == 0 && zipService) {
        messageStatus = AMDServiceConnectionSendMessage(
            zipService,
            (__bridge CFTypeRef)@{ @"MediaSubdir": source },
            kCFPropertyListBinaryFormat_v1_0);
        if (messageStatus == 0) archiveSent = SendAll(zipService, archive);
        if (archiveSent) {
            int socket = AMDServiceConnectionGetSocket(zipService);
            struct timeval timeout = { .tv_sec = 30, .tv_usec = 0 };
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       sizeof(timeout));
            CFPropertyListFormat format = kCFPropertyListBinaryFormat_v1_0;
            responseStatus = AMDServiceConnectionReceiveMessage(
                zipService, &response, &format);
        }
    }
    if (response) CFRelease(response);
    if (zipService) AMDServiceConnectionInvalidate(zipService);

    NSString *link =
        [source stringByAppendingPathComponent:@"p0/p1/p2/link"];
    BOOL sourceObjects = AFCExists(session->afc, source) &&
        AFCExists(session->afc, link) &&
        AFCExists(session->afc,
                  [source stringByAppendingPathComponent:@"payload"]) &&
        AFCExists(session->afc,
                  [source stringByAppendingPathComponent:@"barrier"]);
    BOOL directoriesReady = EnsureDirectory(session->afc, @"Books") &&
        EnsureDirectory(session->afc, @"Books/Sync");
    BOOL booksWritten = sourceObjects && directoriesReady &&
        AFCWriteFile(session->afc, @"Books/Sync/Books.plist", books);
    BOOL ok = serviceStatus == 0 && messageStatus == 0 && archiveSent &&
        sourceObjects && booksWritten;
    return @{ @"ok": @(ok),
              @"cleanupAuthorized": @YES,
              @"safeArguments": @YES,
              @"booksPreimageStable": @YES,
              @"freshPaths": @YES,
              @"zipServiceStatus": @(serviceStatus),
              @"zipMessageStatus": @(messageStatus),
              @"zipResponseStatus": @(responseStatus),
              @"archiveSent": @(archiveSent),
              @"sourceObjectsPresent": @(sourceObjects),
              @"booksWritten": @(booksWritten) };
}

static NSDictionary *Finish(DeviceSession *session, NSArray<NSString *> *args) {
    NSString *source = args[0];
    NSString *linkDestination = args[1];
    NSString *recovered = args[2];
    NSData *expected = [NSData dataWithContentsOfFile:args[3]];
    NSString *targetTail = args[4];
    NSString *targetLeaf = args[5];
    NSString *waitArgument = args[6];
    NSString *snapshotRoot = args[7];
    NSDictionary *snapshot = LoadBooksSnapshot(snapshotRoot);
    BOOL safeArguments =
        GeneratedNamesMatch(source, linkDestination, recovered) &&
        IsSafeRelativePath(targetTail) && IsCanaryLeaf(targetLeaf) &&
        expected.length > 0 && expected.length < 4096 &&
        snapshot != nil &&
        ([waitArgument isEqual:@"0"] || [waitArgument isEqual:@"1"]);
    if (!safeArguments)
        return @{ @"ok": @NO, @"safeArguments": @NO };

    NSData *observed = nil;
    NSUInteger readbackAttempts = 0;
    NSUInteger maximumAttempts = [waitArgument isEqual:@"1"] ? 60 : 1;
    for (NSUInteger index = 0; index < maximumAttempts; index++) {
        readbackAttempts++;
        observed = AFCReadFile(session->afc, recovered);
        if ([observed isEqualToData:expected]) break;
        if (index + 1 < maximumAttempts) usleep(250000);
    }
    BOOL recoveredPresent = observed != nil;
    BOOL bytesMatch = recoveredPresent && [observed isEqualToData:expected];
    NSMutableArray<NSString *> *failures = NSMutableArray.array;

    NSString *targetThroughLink =
        [linkDestination stringByAppendingPathComponent:targetLeaf];
    if (!RemoveIfPresent(session->afc, targetThroughLink))
        [failures addObject:@"target canary"];
    BOOL targetAbsent = !AFCExists(session->afc, targetThroughLink);
    if (!RemoveIfPresent(session->afc, linkDestination))
        [failures addObject:@"relocated link"];
    if (!RemoveIfPresent(session->afc, recovered))
        [failures addObject:@"recovered file"];
    if (!RemoveGeneratedTree(session->afc, source, 0))
        [failures addObject:@"StreamingZip tree"];
    sleep(2);
    NSDictionary *booksRestore = RestoreBooksState(session->afc, snapshotRoot);
    BOOL booksRestored = [booksRestore[@"ok"] boolValue];
    if (!booksRestored) [failures addObject:@"Books preimage"];

    BOOL sourceAbsent = !AFCExists(session->afc, source);
    BOOL linkAbsent = !AFCExists(session->afc, linkDestination);
    BOOL recoveredAbsent = !AFCExists(session->afc, recovered);
    BOOL cleanupComplete = failures.count == 0 && targetAbsent &&
        sourceAbsent && linkAbsent && recoveredAbsent && booksRestored;
    return @{ @"ok": @(bytesMatch && cleanupComplete),
              @"safeArguments": @YES,
              @"recoveredPresent": @(recoveredPresent),
              @"recoveredBytesMatch": @(bytesMatch),
              @"readbackAttempts": @(readbackAttempts),
              @"observedLength": @(observed.length),
              @"cleanupComplete": @(cleanupComplete),
              @"cleanupFailureCount": @(failures.count),
              @"failures": failures,
              @"targetAbsent": @(targetAbsent),
              @"sourceAbsent": @(sourceAbsent),
              @"linkAbsent": @(linkAbsent),
              @"recoveredAbsent": @(recoveredAbsent),
              @"booksPreimageRestored": @(booksRestored),
              @"booksRestore": booksRestore };
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) return 64;
        NSString *command = [NSString stringWithUTF8String:argv[1]];
        TargetIdentifier = CFStringCreateWithCString(
            kCFAllocatorDefault, argv[2], kCFStringEncodingUTF8);
        if (!TargetIdentifier) return 64;

        DeviceSession session;
        OpenSession(&session);
        NSDictionary *summary = SessionSummary(&session);
        BOOL targetTested = NO;
        BOOL targetGatePassed = TargetGate(summary, &targetTested);
        NSDictionary *operation = nil;
        if (session.afcStatus == 0 && session.afc && targetGatePassed) {
            if ([command isEqual:@"probe"] && argc == 3) {
                NSArray<NSString *> *presentPaths =
                    PresentTrackedBooksPaths(session.afc);
                operation = @{ @"ok": @YES,
                    @"booksStagingAbsent":
                        @(AllTrackedBooksFilesAbsent(session.afc)),
                    @"presentBooksPaths": presentPaths,
                    @"fixedSyncInputPresent":
                        @([presentPaths containsObject:@"Books/Sync/Books.plist"]),
                    @"booksSyncPlistPresent":
                        @(AFCExists(session.afc, @"Books/Sync/Books.plist")) };
            } else if ([command isEqual:@"snapshot-books"] && argc == 4) {
                operation = SnapshotBooksState(
                    session.afc, [NSString stringWithUTF8String:argv[3]]);
            } else if ([command isEqual:@"snapshot-and-stage"] && argc == 9) {
                NSString *snapshotRoot =
                    [NSString stringWithUTF8String:argv[8]];
                NSDictionary *snapshot = SnapshotBooksState(
                    session.afc, snapshotRoot);
                NSDictionary *stage = [snapshot[@"ok"] boolValue]
                    ? Stage(&session, @[
                        [NSString stringWithUTF8String:argv[3]],
                        [NSString stringWithUTF8String:argv[4]],
                        [NSString stringWithUTF8String:argv[5]],
                        [NSString stringWithUTF8String:argv[6]],
                        [NSString stringWithUTF8String:argv[7]],
                        snapshotRoot,
                    ])
                    : @{ @"ok": @NO };
                operation = @{ @"ok": @([snapshot[@"ok"] boolValue] &&
                                          [stage[@"ok"] boolValue]),
                               @"snapshot": snapshot,
                               @"stage": stage };
            } else if ([command isEqual:@"restore-books"] && argc == 4) {
                operation = RestoreBooksState(
                    session.afc, [NSString stringWithUTF8String:argv[3]]);
            } else if ([command isEqual:@"pull-generated"] && argc == 5) {
                operation = PullGenerated(
                    session.afc,
                    [NSString stringWithUTF8String:argv[3]],
                    [NSString stringWithUTF8String:argv[4]],
                    NO);
            } else if ([command isEqual:@"pull-card-catalog"] && argc == 5) {
                operation = PullGenerated(
                    session.afc,
                    [NSString stringWithUTF8String:argv[3]],
                    [NSString stringWithUTF8String:argv[4]],
                    YES);
            } else if ([command isEqual:@"generated-status"] && argc == 7) {
                operation = GeneratedStatus(session.afc, @[
                    [NSString stringWithUTF8String:argv[3]],
                    [NSString stringWithUTF8String:argv[4]],
                    [NSString stringWithUTF8String:argv[5]],
                    [NSString stringWithUTF8String:argv[6]],
                ]);
            } else if ([command isEqual:@"wait-generated-status"] && argc == 9) {
                operation = WaitGeneratedStatus(session.afc, @[
                    [NSString stringWithUTF8String:argv[3]],
                    [NSString stringWithUTF8String:argv[4]],
                    [NSString stringWithUTF8String:argv[5]],
                    [NSString stringWithUTF8String:argv[6]],
                    [NSString stringWithUTF8String:argv[7]],
                    [NSString stringWithUTF8String:argv[8]],
                ]);
            } else if ([command isEqual:@"cleanup-generated"] && argc == 8) {
                operation = CleanupGenerated(session.afc, @[
                    [NSString stringWithUTF8String:argv[3]],
                    [NSString stringWithUTF8String:argv[4]],
                    [NSString stringWithUTF8String:argv[5]],
                    [NSString stringWithUTF8String:argv[6]],
                    [NSString stringWithUTF8String:argv[7]],
                ]);
            } else if ([command isEqual:@"stage"] && argc == 9) {
                operation = Stage(&session, @[
                    [NSString stringWithUTF8String:argv[3]],
                    [NSString stringWithUTF8String:argv[4]],
                    [NSString stringWithUTF8String:argv[5]],
                    [NSString stringWithUTF8String:argv[6]],
                    [NSString stringWithUTF8String:argv[7]],
                    [NSString stringWithUTF8String:argv[8]],
                ]);
            } else if ([command isEqual:@"finish"] && argc == 11) {
                operation = Finish(&session, @[
                    [NSString stringWithUTF8String:argv[3]],
                    [NSString stringWithUTF8String:argv[4]],
                    [NSString stringWithUTF8String:argv[5]],
                    [NSString stringWithUTF8String:argv[6]],
                    [NSString stringWithUTF8String:argv[7]],
                    [NSString stringWithUTF8String:argv[8]],
                    [NSString stringWithUTF8String:argv[9]],
                    [NSString stringWithUTF8String:argv[10]],
                ]);
            }
        }

        NSMutableDictionary *result = summary.mutableCopy;
        result[@"targetGatePassed"] = @(targetGatePassed);
        result[@"targetTested"] = @(targetTested);
        result[@"command"] = command ?: @"(nil)";
        result[@"operation"] = operation ?: @{ @"ok": @NO };
        PrintJSON(result);
        BOOL ok = targetGatePassed && session.afcStatus == 0 &&
            [operation[@"ok"] boolValue];
        CloseSession(&session);
        CFRelease(TargetIdentifier);
        return ok ? 0 : 2;
    }
}
