//
//  SteamGridDBManager.m
//  Starlight
//

#import "SteamGridDBManager.h"

NSString* const SteamGridDBArtworkUpdatedNotification = @"StarlightArtworkUpdated";
NSString* const SteamGridDBKindGrid = @"grid";
NSString* const SteamGridDBKindHero = @"hero";
NSString* const SteamGridDBKindLogo = @"logo";
NSString* const SteamGridDBKindIcon = @"icon";

static NSString* const kApiKeyDefaultsKey = @"StarlightSteamGridDBKey";
static NSString* const kApiBase = @"https://www.steamgriddb.com/api/v2/";
static NSString* const kNoMatchMarker = @"none";

@implementation SteamGridDBManager {
    dispatch_queue_t _workQueue;
    NSURLSession* _session;
}

+ (instancetype)sharedManager {
    static SteamGridDBManager* shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[SteamGridDBManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _workQueue = dispatch_queue_create("starlight.steamgriddb", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 20;
        _session = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}

#pragma mark - API key

- (NSString*)apiKey {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kApiKeyDefaultsKey];
}

- (void)setApiKey:(NSString*)apiKey {
    NSString* trimmed = [apiKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kApiKeyDefaultsKey];
    }
    else {
        [[NSUserDefaults standardUserDefaults] setObject:trimmed forKey:kApiKeyDefaultsKey];
    }
}

- (BOOL)isConfigured {
    return self.apiKey.length > 0;
}

#pragma mark - Cache

- (NSString*)cacheRoot {
    NSString* caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [caches stringByAppendingPathComponent:@"SteamGridDB"];
}

// "The Witcher 3: Wild Hunt" -> "the-witcher-3-wild-hunt"
- (NSString*)keyForName:(NSString*)name {
    NSMutableString* key = [NSMutableString string];
    BOOL lastWasDash = NO;
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:c]) {
            [key appendString:[[NSString stringWithCharacters:&c length:1] lowercaseString]];
            lastWasDash = NO;
        }
        else if (!lastWasDash && key.length > 0) {
            [key appendString:@"-"];
            lastWasDash = YES;
        }
    }
    while ([key hasSuffix:@"-"]) {
        [key deleteCharactersInRange:NSMakeRange(key.length - 1, 1)];
    }
    return key.length > 0 ? key : @"unnamed";
}

- (NSString*)directoryForName:(NSString*)name {
    return [[self cacheRoot] stringByAppendingPathComponent:[self keyForName:name]];
}

- (NSString*)cachedPathForAppName:(NSString*)name kind:(NSString*)kind {
    if (name.length == 0) {
        return nil;
    }
    NSString* path = [[self directoryForName:name] stringByAppendingPathComponent:kind];
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

- (void)clearCache {
    [[NSFileManager defaultManager] removeItemAtPath:[self cacheRoot] error:nil];
}

// Host entries that aren't games and would only produce wrong matches
- (BOOL)isNonGameName:(NSString*)name {
    static NSSet* nonGames;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        nonGames = [NSSet setWithArray:@[@"desktop", @"steam big picture", @"big picture",
                                         @"remote input", @"remote monitor", @"playnite",
                                         @"playnite fullscreen", @"playnite desktop", @"virtual desktop"]];
    });
    return [nonGames containsObject:[[name lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
}

#pragma mark - Networking (called on the work queue)

- (NSData*)syncGet:(NSURL*)url authorized:(BOOL)authorized statusCode:(NSInteger*)statusCode {
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    if (authorized) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", self.apiKey] forHTTPHeaderField:@"Authorization"];
    }

    __block NSData* result = nil;
    __block NSInteger status = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[_session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            status = ((NSHTTPURLResponse*)response).statusCode;
        }
        if (error == nil && status >= 200 && status < 300) {
            result = data;
        }
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

    if (statusCode != NULL) {
        *statusCode = status;
    }
    return result;
}

// Returns the "data" array of a SteamGridDB response, or nil on failure
- (NSArray*)apiGet:(NSString*)pathAndQuery statusCode:(NSInteger*)statusCode {
    NSURL* url = [NSURL URLWithString:[kApiBase stringByAppendingString:pathAndQuery]];
    if (url == nil) {
        return nil;
    }
    NSData* data = [self syncGet:url authorized:YES statusCode:statusCode];
    if (data == nil) {
        return nil;
    }
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]] || ![json[@"success"] boolValue]) {
        return nil;
    }
    NSArray* items = json[@"data"];
    return [items isKindOfClass:[NSArray class]] ? items : nil;
}

- (BOOL)downloadFirstOf:(NSArray*)items toPath:(NSString*)path {
    for (NSDictionary* item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString* urlString = item[@"url"];
        NSURL* url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
        if (url == nil) {
            continue;
        }
        NSData* image = [self syncGet:url authorized:NO statusCode:NULL];
        if (image.length > 0 && [image writeToFile:path atomically:YES]) {
            return YES;
        }
    }
    return NO;
}

typedef NS_ENUM(NSInteger, ArtworkFetchResult) {
    ArtworkFetchResultFetched,
    ArtworkFetchResultSkipped,
    ArtworkFetchResultNotFound,
    ArtworkFetchResultFailed,
};

- (ArtworkFetchResult)fetchArtworkForName:(NSString*)name force:(BOOL)force {
    if ([self isNonGameName:name]) {
        return ArtworkFetchResultSkipped;
    }

    NSString* dir = [self directoryForName:name];
    NSFileManager* fm = [NSFileManager defaultManager];
    if (!force &&
        ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:SteamGridDBKindGrid]] ||
         [fm fileExistsAtPath:[dir stringByAppendingPathComponent:kNoMatchMarker]])) {
        return ArtworkFetchResultSkipped;
    }

    NSString* term = [name stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    term = [term stringByReplacingOccurrencesOfString:@"/" withString:@"%2F"];
    NSInteger status = 0;
    NSArray* matches = [self apiGet:[NSString stringWithFormat:@"search/autocomplete/%@", term] statusCode:&status];
    if (matches == nil) {
        Log(LOG_W, @"SteamGridDB search failed for %@ (HTTP %ld)", name, (long)status);
        return ArtworkFetchResultFailed;
    }

    if (force) {
        [fm removeItemAtPath:dir error:nil];
    }
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSDictionary* match = matches.firstObject;
    if (![match isKindOfClass:[NSDictionary class]] || match[@"id"] == nil) {
        [[NSData data] writeToFile:[dir stringByAppendingPathComponent:kNoMatchMarker] atomically:YES];
        Log(LOG_I, @"SteamGridDB has no match for %@", name);
        return ArtworkFetchResultNotFound;
    }

    NSString* gameId = [NSString stringWithFormat:@"%@", match[@"id"]];
    NSDictionary* info = @{ @"id": gameId, @"name": match[@"name"] ?: @"", @"query": name };
    [[NSJSONSerialization dataWithJSONObject:info options:0 error:nil] writeToFile:[dir stringByAppendingPathComponent:@"match.json"] atomically:YES];

    NSDictionary<NSString*, NSString*>* endpoints = @{
        SteamGridDBKindGrid: [NSString stringWithFormat:@"grids/game/%@?dimensions=600x900&types=static", gameId],
        SteamGridDBKindHero: [NSString stringWithFormat:@"heroes/game/%@?types=static", gameId],
        SteamGridDBKindLogo: [NSString stringWithFormat:@"logos/game/%@?types=static&mimes=image/png", gameId],
        SteamGridDBKindIcon: [NSString stringWithFormat:@"icons/game/%@?types=static&mimes=image/png", gameId],
    };

    BOOL gotAny = NO;
    for (NSString* kind in @[SteamGridDBKindGrid, SteamGridDBKindHero, SteamGridDBKindLogo, SteamGridDBKindIcon]) {
        NSArray* items = [self apiGet:endpoints[kind] statusCode:NULL];
        if (items.count > 0 && [self downloadFirstOf:items toPath:[dir stringByAppendingPathComponent:kind]]) {
            gotAny = YES;
        }
    }

    Log(LOG_I, @"SteamGridDB artwork for %@ -> %@ (%@)", name, match[@"name"], gotAny ? @"ok" : @"no images");
    return gotAny ? ArtworkFetchResultFetched : ArtworkFetchResultNotFound;
}

#pragma mark - Public fetch

- (void)fetchArtworkForAppNames:(NSArray<NSString*>*)names
                          force:(BOOL)force
                     completion:(void (^)(NSUInteger, NSUInteger, NSUInteger))completion {
    if (![self isConfigured] || names.count == 0) {
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(0, 0, 0); });
        }
        return;
    }

    // De-duplicate (the same game can exist on several PCs)
    NSArray* uniqueNames = [[NSOrderedSet orderedSetWithArray:names] array];

    dispatch_async(_workQueue, ^{
        NSUInteger fetched = 0, notFound = 0, failed = 0;
        for (NSString* name in uniqueNames) {
            ArtworkFetchResult result = [self fetchArtworkForName:name force:force];
            switch (result) {
                case ArtworkFetchResultFetched:
                    fetched++;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[NSNotificationCenter defaultCenter] postNotificationName:SteamGridDBArtworkUpdatedNotification object:name];
                    });
                    break;
                case ArtworkFetchResultNotFound:
                    notFound++;
                    break;
                case ArtworkFetchResultFailed:
                    failed++;
                    break;
                case ArtworkFetchResultSkipped:
                    break;
            }
        }
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(fetched, notFound, failed); });
        }
    });
}

@end
