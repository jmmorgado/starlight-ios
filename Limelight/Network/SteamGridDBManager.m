//
//  SteamGridDBManager.m
//  Starlight
//

#import "SteamGridDBManager.h"
#import <Security/Security.h>

NSString* const SteamGridDBArtworkUpdatedNotification = @"StarlightArtworkUpdated";
NSString* const SteamGridDBKindGrid = @"grid";
NSString* const SteamGridDBKindHero = @"hero";
NSString* const SteamGridDBKindLogo = @"logo";
NSString* const SteamGridDBKindIcon = @"icon";
NSString* const SteamGridDBKindWide = @"wide";

static NSString* const kApiKeyDefaultsKey = @"StarlightSteamGridDBKey";   // legacy location, migrated to the Keychain
static NSString* const kKeychainService = @"StarlightSteamGridDB";
static NSString* const kApiBase = @"https://www.steamgriddb.com/api/v2/";
static NSString* const kNoMatchMarker = @"none";
static NSString* const kMatchOverridesKey = @"StarlightSteamGridDBMatchOverrides";   // name key -> { id, name }
static NSString* const kArtOverridesKey = @"StarlightSteamGridDBArtOverrides";       // name key -> { kind: url }

@implementation SteamGridDBManager {
    dispatch_queue_t _workQueue;
    NSURLSession* _session;
    NSString* _cachedKey;   // "" once read and empty
    NSMutableDictionary<NSString*, NSNumber*>* _knownSteamAppIds;   // name key -> Steam appid
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

- (NSDictionary*)keychainQuery {
    return @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: kKeychainService,
              (__bridge id)kSecAttrAccount: @"apiKey" };
}

- (NSString*)keychainKey {
    NSMutableDictionary* query = [[self keychainQuery] mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || result == NULL) {
        return nil;
    }
    NSData* data = (__bridge_transfer NSData*)result;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)storeKeychainKey:(NSString*)key {
    SecItemDelete((__bridge CFDictionaryRef)[self keychainQuery]);
    if (key.length == 0) {
        return;
    }
    NSMutableDictionary* item = [[self keychainQuery] mutableCopy];
    item[(__bridge id)kSecValueData] = [key dataUsingEncoding:NSUTF8StringEncoding];
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    SecItemAdd((__bridge CFDictionaryRef)item, NULL);
}

- (NSString*)apiKey {
    @synchronized (self) {
        if (_cachedKey == nil) {
            NSString* key = [self keychainKey];
            if (key.length == 0) {
                // Earlier builds kept the key in NSUserDefaults: move it to the Keychain
                NSString* legacy = [[NSUserDefaults standardUserDefaults] stringForKey:kApiKeyDefaultsKey];
                if (legacy.length > 0) {
                    [self storeKeychainKey:legacy];
                    key = legacy;
                }
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:kApiKeyDefaultsKey];
            }
            _cachedKey = key ?: @"";
        }
        return _cachedKey.length > 0 ? _cachedKey : nil;
    }
}

- (void)setApiKey:(NSString*)apiKey {
    NSString* trimmed = [apiKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    @synchronized (self) {
        [self storeKeychainKey:trimmed];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kApiKeyDefaultsKey];
        _cachedKey = trimmed;
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
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kMatchOverridesKey];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kArtOverridesKey];
}

- (NSDictionary*)matchOverrideForName:(NSString*)name {
    NSDictionary* all = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kMatchOverridesKey];
    NSDictionary* entry = all[[self keyForName:name]];
    return [entry isKindOfClass:[NSDictionary class]] ? entry : nil;
}

- (NSDictionary*)artOverridesForName:(NSString*)name {
    NSDictionary* all = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kArtOverridesKey];
    NSDictionary* entry = all[[self keyForName:name]];
    return [entry isKindOfClass:[NSDictionary class]] ? entry : @{};
}

- (NSString*)endpointForKind:(NSString*)kind gameId:(NSString*)gameId {
    if ([kind isEqualToString:SteamGridDBKindGrid]) {
        return [NSString stringWithFormat:@"grids/game/%@?dimensions=600x900&types=static", gameId];
    }
    if ([kind isEqualToString:SteamGridDBKindHero]) {
        return [NSString stringWithFormat:@"heroes/game/%@?types=static", gameId];
    }
    if ([kind isEqualToString:SteamGridDBKindWide]) {
        return [NSString stringWithFormat:@"grids/game/%@?dimensions=460x215,920x430&types=static", gameId];
    }
    if ([kind isEqualToString:SteamGridDBKindLogo]) {
        return [NSString stringWithFormat:@"logos/game/%@?types=static&mimes=image/png", gameId];
    }
    return [NSString stringWithFormat:@"icons/game/%@?types=static&mimes=image/png", gameId];
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

// Returns the "data" object of a SteamGridDB response (for endpoints that return a single item)
- (NSDictionary*)apiGetObject:(NSString*)pathAndQuery statusCode:(NSInteger*)statusCode {
    NSURL* url = [NSURL URLWithString:[kApiBase stringByAppendingString:pathAndQuery]];
    NSData* data = url != nil ? [self syncGet:url authorized:YES statusCode:statusCode] : nil;
    NSDictionary* json = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:[NSDictionary class]] || ![json[@"success"] boolValue]) {
        return nil;
    }
    NSDictionary* item = json[@"data"];
    return [item isKindOfClass:[NSDictionary class]] ? item : nil;
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

- (NSDictionary*)storedMatchInDirectory:(NSString*)dir {
    NSData* data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"match.json"]];
    NSDictionary* info = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [info isKindOfClass:[NSDictionary class]] ? info : nil;
}

// steamAppId: the game's Steam appid when the PC reports it (0 otherwise). SteamGridDB looks
// Steam games up by appid, which always finds the right edition; other games are searched by name.
- (ArtworkFetchResult)fetchArtworkForName:(NSString*)name steamAppId:(unsigned long long)steamAppId force:(BOOL)force {
    if ([self isNonGameName:name]) {
        return ArtworkFetchResultSkipped;
    }

    NSString* dir = [self directoryForName:name];
    NSFileManager* fm = [NSFileManager defaultManager];
    NSDictionary* manual = [self matchOverrideForName:name];
    NSString* appIdString = steamAppId > 0 ? [NSString stringWithFormat:@"%llu", steamAppId] : @"";

    if (!force) {
        // "No match" is remembered per appid, so a game that gains an appid is tried again
        NSString* noMatchPath = [dir stringByAppendingPathComponent:kNoMatchMarker];
        if ([fm fileExistsAtPath:noMatchPath]) {
            NSString* triedAppId = [NSString stringWithContentsOfFile:noMatchPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
            if (steamAppId == 0 || manual[@"id"] != nil || [triedAppId isEqualToString:appIdString]) {
                return ArtworkFetchResultSkipped;
            }
        }
        NSDictionary* stored = [self storedMatchInDirectory:dir];
        if (stored != nil) {
            // Already matched. Matches made by name before the appid was known are redone once by appid.
            NSString* storedAppId = [NSString stringWithFormat:@"%@", stored[@"steamAppId"] ?: @""];
            if (steamAppId == 0 || manual[@"id"] != nil || [storedAppId isEqualToString:appIdString]) {
                return ArtworkFetchResultSkipped;
            }
        }
        else if (steamAppId == 0 && [fm fileExistsAtPath:[dir stringByAppendingPathComponent:SteamGridDBKindGrid]]) {
            // Art picked by hand without a match file
            return ArtworkFetchResultSkipped;
        }
    }

    NSInteger status = 0;
    NSArray* matches = nil;
    NSString* source = @"name";
    if (manual[@"id"] != nil) {
        // The user picked the game by hand
        matches = @[manual];
        source = @"manual";
    }
    else {
        if (steamAppId > 0) {
            NSDictionary* game = [self apiGetObject:[NSString stringWithFormat:@"games/steam/%llu", steamAppId] statusCode:&status];
            if (game[@"id"] != nil) {
                matches = @[game];
                source = @"steam";
            }
            else if (status != 404 && status != 0 && (status < 200 || status >= 300)) {
                Log(LOG_W, @"SteamGridDB appid lookup failed for %@ (%llu, HTTP %ld)", name, steamAppId, (long)status);
                return ArtworkFetchResultFailed;
            }
        }
        if (matches == nil) {
            NSString* term = [name stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
            term = [term stringByReplacingOccurrencesOfString:@"/" withString:@"%2F"];
            matches = [self apiGet:[NSString stringWithFormat:@"search/autocomplete/%@", term] statusCode:&status];
        }
    }
    if (matches == nil) {
        Log(LOG_W, @"SteamGridDB search failed for %@ (HTTP %ld)", name, (long)status);
        return ArtworkFetchResultFailed;
    }

    BOOL rematch = !force && [self storedMatchInDirectory:dir] != nil;
    if (force || rematch) {
        [fm removeItemAtPath:dir error:nil];
    }
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSDictionary* match = matches.firstObject;
    if (![match isKindOfClass:[NSDictionary class]] || match[@"id"] == nil) {
        [appIdString writeToFile:[dir stringByAppendingPathComponent:kNoMatchMarker] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Log(LOG_I, @"SteamGridDB has no match for %@", name);
        return ArtworkFetchResultNotFound;
    }

    NSString* gameId = [NSString stringWithFormat:@"%@", match[@"id"]];
    NSDictionary* info = @{ @"id": gameId, @"name": match[@"name"] ?: @"", @"query": name,
                            @"steamAppId": appIdString, @"source": source };
    [[NSJSONSerialization dataWithJSONObject:info options:0 error:nil] writeToFile:[dir stringByAppendingPathComponent:@"match.json"] atomically:YES];

    NSDictionary* chosen = [self artOverridesForName:name];
    BOOL gotAny = NO;
    for (NSString* kind in @[SteamGridDBKindGrid, SteamGridDBKindHero, SteamGridDBKindLogo, SteamGridDBKindIcon]) {
        NSString* path = [dir stringByAppendingPathComponent:kind];
        NSString* chosenURL = chosen[kind];
        if ([chosenURL isKindOfClass:[NSString class]] && [self downloadFirstOf:@[@{ @"url": chosenURL }] toPath:path]) {
            gotAny = YES;
            continue;
        }
        NSArray* items = [self apiGet:[self endpointForKind:kind gameId:gameId] statusCode:NULL];
        if (items.count > 0 && [self downloadFirstOf:items toPath:path]) {
            gotAny = YES;
        }
    }

    Log(LOG_I, @"SteamGridDB artwork for %@ -> %@ via %@ (%@)", name, match[@"name"], source, gotAny ? @"ok" : @"no images");
    return gotAny ? ArtworkFetchResultFetched : ArtworkFetchResultNotFound;
}

#pragma mark - Manual choices

- (NSDictionary*)matchForAppName:(NSString*)name {
    if (name.length == 0) {
        return nil;
    }
    NSData* data = [NSData dataWithContentsOfFile:[[self directoryForName:name] stringByAppendingPathComponent:@"match.json"]];
    NSDictionary* info = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([info isKindOfClass:[NSDictionary class]] && info[@"id"] != nil) {
        return info;
    }
    return [self matchOverrideForName:name];
}

- (void)searchGames:(NSString*)term completion:(void (^)(NSArray<NSDictionary*>*))completion {
    NSString* trimmed = [term stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![self isConfigured] || trimmed.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(trimmed.length == 0 ? @[] : nil); });
        return;
    }
    dispatch_async(_workQueue, ^{
        NSString* encoded = [trimmed stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
        encoded = [encoded stringByReplacingOccurrencesOfString:@"/" withString:@"%2F"];
        NSArray* items = [self apiGet:[NSString stringWithFormat:@"search/autocomplete/%@", encoded] statusCode:NULL];
        NSMutableArray* results = items != nil ? [NSMutableArray array] : nil;
        for (NSDictionary* item in items) {
            if (![item isKindOfClass:[NSDictionary class]] || item[@"id"] == nil) {
                continue;
            }
            NSString* year = @"";
            id released = item[@"release_date"];
            if ([released isKindOfClass:[NSNumber class]] && [released doubleValue] > 0) {
                NSDateComponents* parts = [[NSCalendar currentCalendar] components:NSCalendarUnitYear
                                                                          fromDate:[NSDate dateWithTimeIntervalSince1970:[released doubleValue]]];
                year = [NSString stringWithFormat:@"%ld", (long)parts.year];
            }
            [results addObject:@{ @"id": [NSString stringWithFormat:@"%@", item[@"id"]],
                                  @"name": [item[@"name"] isKindOfClass:[NSString class]] ? item[@"name"] : @"",
                                  @"year": year,
                                  @"verified": @([item[@"verified"] boolValue]) }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(results); });
    });
}

- (void)artworkOptionsForAppName:(NSString*)name kind:(NSString*)kind completion:(void (^)(NSArray<NSDictionary*>*))completion {
    NSString* gameId = [self matchForAppName:name][@"id"];
    if (![self isConfigured] || gameId == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); });
        return;
    }
    gameId = [NSString stringWithFormat:@"%@", gameId];
    dispatch_async(_workQueue, ^{
        NSArray* items = [self apiGet:[self endpointForKind:kind gameId:gameId] statusCode:NULL];
        NSMutableArray* options = items != nil ? [NSMutableArray array] : nil;
        for (NSDictionary* item in items) {
            if (![item isKindOfClass:[NSDictionary class]] || ![item[@"url"] isKindOfClass:[NSString class]]) {
                continue;
            }
            NSString* thumb = [item[@"thumb"] isKindOfClass:[NSString class]] ? item[@"thumb"] : item[@"url"];
            [options addObject:@{ @"url": item[@"url"], @"thumb": thumb }];
            if (options.count >= 40) {
                break;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(options); });
    });
}

- (void)setMatchForAppName:(NSString*)name gameId:(NSString*)gameId gameName:(NSString*)gameName completion:(void (^)(BOOL))completion {
    NSString* key = [self keyForName:name];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary* matches = [[defaults dictionaryForKey:kMatchOverridesKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    matches[key] = @{ @"id": gameId, @"name": gameName ?: @"" };
    [defaults setObject:matches forKey:kMatchOverridesKey];
    // Images picked for the previous game no longer apply
    NSMutableDictionary* art = [[defaults dictionaryForKey:kArtOverridesKey] mutableCopy];
    [art removeObjectForKey:key];
    [defaults setObject:art ?: @{} forKey:kArtOverridesKey];

    dispatch_async(_workQueue, ^{
        ArtworkFetchResult result = [self fetchArtworkForName:name steamAppId:[self knownSteamAppIdForName:name] force:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SteamGridDBArtworkUpdatedNotification object:name];
            if (completion != nil) {
                completion(result == ArtworkFetchResultFetched);
            }
        });
    });
}

- (void)setArtworkForAppName:(NSString*)name kind:(NSString*)kind url:(NSString*)url completion:(void (^)(BOOL))completion {
    NSString* key = [self keyForName:name];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary* art = [[defaults dictionaryForKey:kArtOverridesKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary* entry = [[self artOverridesForName:name] mutableCopy];
    entry[kind] = url;
    art[key] = entry;
    [defaults setObject:art forKey:kArtOverridesKey];

    dispatch_async(_workQueue, ^{
        NSString* dir = [self directoryForName:name];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:kNoMatchMarker] error:nil];
        BOOL ok = [self downloadFirstOf:@[@{ @"url": url }] toPath:[dir stringByAppendingPathComponent:kind]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SteamGridDBArtworkUpdatedNotification object:name];
            if (completion != nil) {
                completion(ok);
            }
        });
    });
}

#pragma mark - Public fetch

- (unsigned long long)knownSteamAppIdForName:(NSString*)name {
    @synchronized (self) {
        return [_knownSteamAppIds[[self keyForName:name]] unsignedLongLongValue];
    }
}

- (void)fetchArtworkForAppNames:(NSArray<NSString*>*)names
                          force:(BOOL)force
                     completion:(void (^)(NSUInteger, NSUInteger, NSUInteger))completion {
    [self fetchArtworkForAppNames:names steamAppIds:nil force:force completion:completion];
}

- (void)fetchArtworkForAppNames:(NSArray<NSString*>*)names
                    steamAppIds:(NSDictionary<NSString*, NSNumber*>*)steamAppIds
                          force:(BOOL)force
                     completion:(void (^)(NSUInteger, NSUInteger, NSUInteger))completion {
    if (steamAppIds.count > 0) {
        @synchronized (self) {
            if (_knownSteamAppIds == nil) {
                _knownSteamAppIds = [NSMutableDictionary dictionary];
            }
            [steamAppIds enumerateKeysAndObjectsUsingBlock:^(NSString* name, NSNumber* appid, BOOL* stop) {
                self->_knownSteamAppIds[[self keyForName:name]] = appid;
            }];
        }
    }
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
            ArtworkFetchResult result = [self fetchArtworkForName:name steamAppId:[self knownSteamAppIdForName:name] force:force];
            switch (result) {
                case ArtworkFetchResultFetched: {
                    fetched++;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[NSNotificationCenter defaultCenter] postNotificationName:SteamGridDBArtworkUpdatedNotification object:name];
                    });
                    break;
                }
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
