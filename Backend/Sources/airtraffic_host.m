#import <Foundation/Foundation.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/select.h>
#include <unistd.h>

typedef void *ATHostConnectionRef;

extern ATHostConnectionRef ATHostConnectionCreate(CFStringRef deviceIdentifier);
extern void ATHostConnectionRelease(ATHostConnectionRef connection);
extern void ATHostConnectionSendHostInfo(ATHostConnectionRef connection,
                                         CFDictionaryRef hostInfo);
extern void ATHostConnectionSendSyncRequest(ATHostConnectionRef connection,
                                            CFArrayRef dataclasses,
                                            CFDictionaryRef anchors,
                                            CFDictionaryRef hostInfo);
extern void ATHostConnectionSendMetadataSyncFinished(
    ATHostConnectionRef connection,
    CFDictionaryRef syncTypes,
    CFDictionaryRef anchors);
extern void ATHostConnectionSendAssetCompleted(ATHostConnectionRef connection,
                                               CFStringRef assetIdentifier,
                                               CFStringRef dataclass,
                                               CFStringRef assetPath);
extern CFDictionaryRef ATHostConnectionReadMessage(ATHostConnectionRef connection);
extern CFStringRef ATCFMessageGetName(CFDictionaryRef message);
extern CFTypeRef ATCFMessageGetParam(CFDictionaryRef message, CFStringRef key);

static void TimeoutHandler(int signalNumber) {
    (void)signalNumber;
    const char message[] = "{\"ok\":false,\"error\":\"timeout\"}\n";
    (void)write(STDOUT_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

static void PrintJSON(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:0
                                                     error:nil];
    if (!data) return;
    (void)write(STDOUT_FILENO, data.bytes, data.length);
    (void)write(STDOUT_FILENO, "\n", 1);
}

static NSDictionary *HostInfo(void) {
    return @{
        @"Type": @"iTunes",
        @"Version": @"13.7.0.161",
        @"MacOSVersion": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"SyncHostName": @"airlift",
        @"LibraryID": NSUUID.UUID.UUIDString,
        @"SyncedDataclasses": @[ @"Book" ],
        @"SyncedAssetTypes": @[ @"Book" ],
        @"Wakeable": @NO,
    };
}

static BOOL ManifestContains(NSDictionary *manifest, NSString *identifier) {
    NSArray *books = [manifest[@"Book"] isKindOfClass:NSArray.class]
        ? manifest[@"Book"] : nil;
    for (id entry in books) {
        if ([entry isKindOfClass:NSDictionary.class] &&
            [entry[@"AssetID"] isEqual:identifier] &&
            [entry[@"IsDownload"] boolValue]) return YES;
    }
    return NO;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        int pairStart = 2;
        NSInteger pauseAfter = -1;
        BOOL stepMode = argc >= 3 && strcmp(argv[2], "--step") == 0;
        if (stepMode) {
            pairStart = 3;
        } else if (argc >= 4 && strcmp(argv[2], "--pause-after") == 0) {
            char *end = NULL;
            long parsed = strtol(argv[3], &end, 10);
            if (!end || *end != '\0' || parsed < 0 || parsed > 6) {
                PrintJSON(@{ @"ok": @NO,
                             @"error": @"invalid pause index" });
                return 64;
            }
            pauseAfter = (NSInteger)parsed;
            pairStart = 4;
        }
        if (argc <= pairStart || (argc - pairStart) % 2 != 0) {
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"usage: airtraffic_host udid [--step | --pause-after index] id path [id path ...]" });
            return 64;
        }

        NSUInteger pairCount = (NSUInteger)(argc - pairStart) / 2;
        if (pairCount > 7 ||
            (pauseAfter >= 0 && (NSUInteger)pauseAfter >= pairCount)) {
            PrintJSON(@{ @"ok": @NO, @"error": @"too many assets" });
            return 64;
        }

        NSString *deviceIdentifier = [NSString stringWithUTF8String:argv[1]];
        NSMutableArray<NSDictionary *> *assets = NSMutableArray.array;
        for (int index = pairStart; index < argc; index += 2) {
            NSString *identifier = [NSString stringWithUTF8String:argv[index]];
            NSString *destination =
                [NSString stringWithUTF8String:argv[index + 1]];
            if (!identifier.length || !destination.length) {
                PrintJSON(@{ @"ok": @NO, @"error": @"empty argument" });
                return 64;
            }
            [assets addObject:@{ @"identifier": identifier,
                                 @"destination": destination }];
        }
        if (!deviceIdentifier.length) {
            PrintJSON(@{ @"ok": @NO, @"error": @"empty device identifier" });
            return 64;
        }

        signal(SIGALRM, TimeoutHandler);
        alarm(100);
        ATHostConnectionRef connection =
            ATHostConnectionCreate((__bridge CFStringRef)deviceIdentifier);
        if (!connection) {
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"AirTraffic connection failed" });
            return 2;
        }

        BOOL syncAllowed = NO;
        for (NSUInteger index = 0; index < 8 && !syncAllowed; index++) {
            CFDictionaryRef raw = ATHostConnectionReadMessage(connection);
            if (!raw) continue;
            NSString *name = (__bridge NSString *)ATCFMessageGetName(raw);
            syncAllowed = [name isEqual:@"SyncAllowed"];
            CFRelease(raw);
        }
        if (!syncAllowed) {
            ATHostConnectionRelease(connection);
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"SyncAllowed not observed" });
            return 3;
        }

        NSDictionary *hostInfo = HostInfo();
        ATHostConnectionSendHostInfo(
            connection, (__bridge CFDictionaryRef)hostInfo);
        if (!stepMode) usleep(200000);
        ATHostConnectionSendSyncRequest(
            connection,
            (__bridge CFArrayRef)@[ @"Book" ],
            (__bridge CFDictionaryRef)@{},
            (__bridge CFDictionaryRef)hostInfo);

        BOOL ready = NO;
        for (NSUInteger index = 0; index < 12 && !ready; index++) {
            CFDictionaryRef raw = ATHostConnectionReadMessage(connection);
            if (!raw) continue;
            NSString *name = (__bridge NSString *)ATCFMessageGetName(raw);
            ready = [name isEqual:@"ReadyForSync"];
            CFRelease(raw);
        }
        if (!ready) {
            ATHostConnectionRelease(connection);
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"ReadyForSync not observed" });
            return 4;
        }

        ATHostConnectionSendMetadataSyncFinished(
            connection,
            (__bridge CFDictionaryRef)@{ @"Book": @1 },
            (__bridge CFDictionaryRef)@{});

        NSDictionary *manifest = nil;
        for (NSUInteger index = 0; index < 20 && !manifest; index++) {
            CFDictionaryRef raw = ATHostConnectionReadMessage(connection);
            if (!raw) continue;
            NSString *name = (__bridge NSString *)ATCFMessageGetName(raw);
            if ([name isEqual:@"AssetManifest"]) {
                id value = (__bridge id)ATCFMessageGetParam(
                    raw, CFSTR("AssetManifest"));
                if ([value isKindOfClass:NSDictionary.class])
                    manifest = [value copy];
            } else if ([name isEqual:@"SyncFailed"] ||
                       [name isEqual:@"SyncFinished"]) {
                CFRelease(raw);
                break;
            }
            CFRelease(raw);
        }

        NSUInteger missing = 0;
        for (NSDictionary *asset in assets)
            if (!ManifestContains(manifest, asset[@"identifier"])) missing++;
        if (missing) {
            ATHostConnectionRelease(connection);
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"expected assets absent from manifest",
                         @"missingCount": @(missing) });
            return 5;
        }

        for (NSUInteger index = 0; index < assets.count; index++) {
            NSDictionary *asset = assets[index];
            ATHostConnectionSendAssetCompleted(
                connection,
                (__bridge CFStringRef)asset[@"identifier"],
                CFSTR("Book"),
                (__bridge CFStringRef)asset[@"destination"]);
            BOOL shouldPause = stepMode ||
                (pauseAfter >= 0 && index == (NSUInteger)pauseAfter);
            if (shouldPause) {
                alarm(0);
                if (stepMode) {
                    NSString *message = [NSString stringWithFormat:
                        @"ready-for-step:%lu\n", (unsigned long)index];
                    NSData *data = [message dataUsingEncoding:NSUTF8StringEncoding];
                    (void)write(STDERR_FILENO, data.bytes, data.length);
                } else {
                    const char readyMessage[] = "ready-for-copy\n";
                    (void)write(STDERR_FILENO,
                                readyMessage,
                                sizeof(readyMessage) - 1);
                }
                fd_set readSet;
                FD_ZERO(&readSet);
                FD_SET(STDIN_FILENO, &readSet);
                struct timeval timeout = { .tv_sec = 120, .tv_usec = 0 };
                int ready = select(STDIN_FILENO + 1,
                                   &readSet,
                                   NULL,
                                   NULL,
                                   &timeout);
                if (ready > 0) {
                    char byte = 0;
                    (void)read(STDIN_FILENO, &byte, 1);
                }
                alarm(100);
            }
            if (!stepMode && index + 1 < assets.count) usleep(900000);
        }
        if (!stepMode) sleep(2);
        ATHostConnectionRelease(connection);
        alarm(0);
        PrintJSON(@{ @"ok": @YES,
                     @"syncAllowed": @YES,
                     @"readyForSync": @YES,
                     @"fileCompleteMessages": @(assets.count),
                     @"stepMode": @(stepMode),
                     @"pausedAfterAsset": @(pauseAfter) });
        return 0;
    }
}
