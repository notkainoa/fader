// Now-playing bridge loaded into /usr/bin/perl by Fader.
//
// Since macOS 15.4 mediaremoted only answers processes whose bundle identifier
// starts with "com.apple.", so a third-party app gets nothing from
// MediaRemote directly. /usr/bin/perl reports itself as com.apple.perl5; Fader
// spawns it, perl dlopens this library through DynaLoader and calls
// fader_media_remote_run(), which never returns.
//
// Unlike Control Center, which shows only the elected player, this reads
// every registered now-playing client, so two apps playing at once both show.
//
// Commands are another matter: mediaremoted sends a command from a client
// without Apple's private entitlement to the elected now-playing app, whatever
// client it names ("missing entitlement needed to send command to arbitrary
// apps"). So each session reports whether it is the elected one, and commands
// for any other client are dropped rather than landing on the wrong app.
//
// Protocol (one message per line):
//   stdout: {"sessions":[{...}, ...]} whenever any session changes.
//   stdin:  "play <pid>", "pause <pid>", "toggle <pid>", "seek <pid> <seconds>".
// EOF on stdin (Fader quit or crashed) ends the process.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <unistd.h>

// Signatures recovered from the arm64 disassembly of macOS 26 MediaRemote.
typedef void (*GetClientsFn)(dispatch_queue_t, void (^)(NSArray *));
typedef void (*GetInfoForClientFn)(id client, id origin, long options, dispatch_queue_t,
                                   void (^)(NSDictionary *, void *));
typedef BOOL (*SendCommandToClientFn)(int command, NSDictionary *options, id origin, id client, int appOptions,
                                      dispatch_queue_t, void (^)(id));
typedef id (*GetLocalOriginFn)(void);
typedef NSString *(*ClientStringFn)(id);
typedef int (*ClientPIDFn)(id);
typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*GetNowPlayingPIDFn)(dispatch_queue_t, void (^)(int));

enum {
    kCommandPlay = 0,
    kCommandPause = 1,
    kCommandTogglePlayPause = 2,
    kCommandChangePlaybackPosition = 24,
};

static GetClientsFn getClients;
static GetInfoForClientFn getInfoForClient;
static SendCommandToClientFn sendCommandToClient;
static GetLocalOriginFn getLocalOrigin;
static ClientStringFn clientBundleID;
static ClientStringFn clientParentBundleID;
static ClientStringFn clientDisplayName;
static ClientPIDFn clientPID;
static RegisterFn registerForNotifications;
static GetNowPlayingPIDFn getNowPlayingPID;
static NSString *playbackPositionKey;

// Everything below is touched only on `queue`.
static dispatch_queue_t queue;
static NSArray *liveClients;
static NSData *lastSnapshot;
static NSMutableDictionary<NSNumber *, NSString *> *sentArtworkKeys;
static BOOL pollInFlight;
static CFAbsoluteTime pollStartedAt;
static BOOL pollScheduled;
static NSMutableData *stdinBuffer;
// Globals so ARC cannot release the sources while dispatch_main parks the thread.
static dispatch_source_t inputSource;
static dispatch_source_t pollTimer;

static void *symbol(void *handle, const char *name) {
    void *sym = dlsym(handle, name);
    if (!sym) fprintf(stderr, "FaderMediaRemote: missing symbol %s\n", name);
    return sym;
}

static BOOL loadMediaRemote(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!handle) return NO;
    getClients = symbol(handle, "MRMediaRemoteGetNowPlayingClients");
    getInfoForClient = symbol(handle, "MRMediaRemoteGetNowPlayingInfoForClient");
    sendCommandToClient = symbol(handle, "MRMediaRemoteSendCommandToClient");
    getLocalOrigin = symbol(handle, "MRMediaRemoteGetLocalOrigin");
    clientBundleID = symbol(handle, "MRNowPlayingClientGetBundleIdentifier");
    clientParentBundleID = symbol(handle, "MRNowPlayingClientGetParentAppBundleIdentifier");
    clientDisplayName = symbol(handle, "MRNowPlayingClientGetDisplayName");
    clientPID = symbol(handle, "MRNowPlayingClientGetProcessIdentifier");
    registerForNotifications = symbol(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    getNowPlayingPID = symbol(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
    NSString *__unsafe_unretained *positionKey =
        (NSString *__unsafe_unretained *)symbol(handle, "kMRMediaRemoteOptionPlaybackPosition");
    playbackPositionKey = positionKey ? *positionKey : nil;
    return getClients && getInfoForClient && sendCommandToClient && getLocalOrigin && clientBundleID && clientPID &&
           getNowPlayingPID;
}

static BOOL processIsAlive(int pid) {
    // mediaremoted keeps a client around for a while after its process exits.
    // EPERM (e.g. under the app sandbox) still means the process exists.
    return pid > 0 && (kill(pid, 0) == 0 || errno != ESRCH);
}

static void writeLine(NSData *data) {
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

// NSJSONSerialization raises (it doesn't return nil) on anything that isn't
// JSON, NaN and infinity included, and live streams report an infinite
// duration. Values from MediaRemote are passed only through these two.
static id jsonString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : [NSNull null];
}

static id jsonNumber(id value) {
    if (![value isKindOfClass:[NSNumber class]] || !isfinite([value doubleValue])) return [NSNull null];
    return value;
}

static NSString *artworkKeyFor(NSDictionary *info) {
    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if (![artwork isKindOfClass:[NSData class]] || artwork.length == 0) return nil;
    NSString *identifier = info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"];
    if ([identifier isKindOfClass:[NSString class]] && identifier.length) return identifier;
    return [NSString stringWithFormat:@"%lu-%lu", (unsigned long)artwork.length, (unsigned long)artwork.hash];
}

static NSMutableDictionary *sessionFor(id client, NSDictionary *info, int electedPID) {
    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    if (![title isKindOfClass:[NSString class]] || title.length == 0) return nil;

    NSMutableDictionary *session = [NSMutableDictionary dictionary];
    session[@"pid"] = @(clientPID(client));
    // @YES/@NO, not @(a == b): the comparison is an int in C and would be
    // written as 1/0, which Fader's Bool decoding rejects.
    session[@"elected"] = clientPID(client) == electedPID ? @YES : @NO;
    session[@"bundleID"] = jsonString(clientBundleID(client));
    session[@"parentBundleID"] = jsonString(clientParentBundleID ? clientParentBundleID(client) : nil);
    session[@"displayName"] = jsonString(clientDisplayName ? clientDisplayName(client) : nil);
    session[@"title"] = title;
    session[@"artist"] = jsonString(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
    session[@"album"] = jsonString(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
    session[@"duration"] = jsonNumber(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
    session[@"elapsed"] = jsonNumber(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
    session[@"rate"] = jsonNumber(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
    NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    session[@"timestamp"] = [timestamp isKindOfClass:[NSDate class]] ? jsonNumber(@(timestamp.timeIntervalSince1970))
                                                                     : [NSNull null];
    session[@"artworkKey"] = jsonString(artworkKeyFor(info));
    return session;
}

static void emit(NSArray<NSMutableDictionary *> *sessions, NSDictionary<NSNumber *, NSDictionary *> *infos) {
    NSData *snapshot = [NSJSONSerialization dataWithJSONObject:sessions options:NSJSONWritingSortedKeys error:nil];
    if (!snapshot || [snapshot isEqualToData:lastSnapshot]) return;
    lastSnapshot = snapshot;

    // Artwork is tens of kilobytes; send it once per key and let Fader cache it.
    NSMutableDictionary<NSNumber *, NSString *> *sent = [NSMutableDictionary dictionary];
    for (NSMutableDictionary *session in sessions) {
        NSNumber *pid = session[@"pid"];
        NSString *key = session[@"artworkKey"];
        if (![key isKindOfClass:[NSString class]]) continue;
        sent[pid] = key;
        if ([sentArtworkKeys[pid] isEqualToString:key]) continue;
        NSData *artwork = infos[pid][@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        session[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
    }
    sentArtworkKeys = sent;

    NSData *line = [NSJSONSerialization dataWithJSONObject:@{@"sessions" : sessions} options:0 error:nil];
    if (line) writeLine(line);
}

static void poll(void) {
    // A client that never answers must not wedge polling forever.
    if (pollInFlight && CFAbsoluteTimeGetCurrent() - pollStartedAt < 5) return;
    pollInFlight = YES;
    pollStartedAt = CFAbsoluteTimeGetCurrent();

    getClients(queue, ^(NSArray *clients) {
        NSMutableArray *live = [NSMutableArray array];
        for (id client in clients) {
            if (processIsAlive(clientPID(client))) [live addObject:client];
        }
        liveClients = live;

        NSMutableDictionary<NSNumber *, NSDictionary *> *infos = [NSMutableDictionary dictionary];
        __block int electedPID = 0;
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        getNowPlayingPID(queue, ^(int pid) {
            electedPID = pid;
            dispatch_group_leave(group);
        });
        id origin = getLocalOrigin();
        for (id client in live) {
            dispatch_group_enter(group);
            getInfoForClient(client, origin, 1, queue, ^(NSDictionary *info, void *unused) {
                (void)unused;
                if ([info isKindOfClass:[NSDictionary class]]) infos[@(clientPID(client))] = info;
                dispatch_group_leave(group);
            });
        }
        dispatch_group_notify(group, queue, ^{
            pollInFlight = NO;
            NSMutableArray *sessions = [NSMutableArray array];
            for (id client in live) {
                NSDictionary *info = infos[@(clientPID(client))];
                NSMutableDictionary *session = info ? sessionFor(client, info, electedPID) : nil;
                if (session) [sessions addObject:session];
            }
            emit(sessions, infos);
        });
    });
}

static void schedulePoll(double delay) {
    if (pollScheduled) return;
    pollScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), queue, ^{
        pollScheduled = NO;
        poll();
    });
}

static id clientWithPID(int pid) {
    for (id client in liveClients) {
        if (clientPID(client) == pid) return client;
    }
    return nil;
}

// Fader updates its UI optimistically when it sends a command. If the command
// was dropped or ignored nothing changes here and no report would go out, so
// the snapshot is forgotten to make the next poll report the real state.
static void forceReport(double delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), queue, ^{
        lastSnapshot = nil;
        poll();
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    if (parts.count < 2) return;
    int pid = parts[1].intValue;
    id client = clientWithPID(pid);
    if (!client) {
        forceReport(0);
        return;
    }

    int command;
    NSDictionary *options = nil;
    NSString *verb = parts[0];
    if ([verb isEqualToString:@"play"]) {
        command = kCommandPlay;
    } else if ([verb isEqualToString:@"pause"]) {
        command = kCommandPause;
    } else if ([verb isEqualToString:@"toggle"]) {
        command = kCommandTogglePlayPause;
    } else if ([verb isEqualToString:@"seek"] && parts.count >= 3 && playbackPositionKey) {
        command = kCommandChangePlaybackPosition;
        options = @{playbackPositionKey : @(parts[2].doubleValue)};
    } else {
        return;
    }
    // The elected app can change between Fader's last report and the click;
    // check again right before sending, since mediaremoted would deliver the
    // command to whichever app is elected now.
    getNowPlayingPID(queue, ^(int electedPID) {
        if (electedPID != pid) {
            fprintf(stderr, "FaderMediaRemote: %d is not the now-playing app (%d); dropped\n", pid, electedPID);
            forceReport(0);
            return;
        }
        sendCommandToClient(command, options, getLocalOrigin(), client, 0, queue, ^(id result) {
            (void)result;
            schedulePoll(0.15);
            forceReport(1.5);
        });
    });
}

static void readStdin(void) {
    char buffer[4096];
    ssize_t count = read(STDIN_FILENO, buffer, sizeof buffer);
    if (count <= 0) exit(0);
    [stdinBuffer appendBytes:buffer length:(NSUInteger)count];
    while (YES) {
        NSRange newline = [stdinBuffer rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                           options:0
                                             range:NSMakeRange(0, stdinBuffer.length)];
        if (newline.location == NSNotFound) break;
        NSData *lineData = [stdinBuffer subdataWithRange:NSMakeRange(0, newline.location)];
        [stdinBuffer replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        if (line.length) handleCommand(line);
    }
}

__attribute__((visibility("default"))) void fader_media_remote_run(void) {
    // Called as a Perl XSUB; the interpreter arguments are deliberately ignored.
    signal(SIGPIPE, SIG_DFL);
    if (!loadMediaRemote()) {
        fprintf(stderr, "FaderMediaRemote: MediaRemote unavailable\n");
        exit(2);
    }

    queue = dispatch_queue_create("dev.pantafive.fader.mediaremote", DISPATCH_QUEUE_SERIAL);
    sentArtworkKeys = [NSMutableDictionary dictionary];
    stdinBuffer = [NSMutableData data];

    inputSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, queue);
    dispatch_source_set_event_handler(inputSource, ^{ readStdin(); });
    dispatch_resume(inputSource);

    // Notifications are not guaranteed for every registered client, so a
    // one-second poll backs them up; they just make the common case instant.
    if (registerForNotifications) registerForNotifications(queue);
    [[NSNotificationCenter defaultCenter] addObserverForName:nil
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
                                                      if ([note.name containsString:@"MRMediaRemote"] ||
                                                          [note.name containsString:@"NowPlaying"]) {
                                                          dispatch_async(queue, ^{ schedulePoll(0.05); });
                                                      }
                                                  }];

    pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(pollTimer, DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC, 250 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(pollTimer, ^{ poll(); });
    dispatch_resume(pollTimer);

    dispatch_main();
}
