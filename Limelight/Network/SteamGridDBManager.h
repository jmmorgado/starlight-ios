//
//  SteamGridDBManager.h
//  Starlight
//
//  Downloads game artwork (cover, hero, logo, icon) from SteamGridDB and
//  caches it on disk, keyed by the game's name so the same game shares art
//  across PCs. Steam games are matched by appid, others by name.
//  The user's API key is stored in the Keychain, never in code.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on the main queue each time a game's artwork finishes downloading
extern NSString* const SteamGridDBArtworkUpdatedNotification;

// Artwork kinds
extern NSString* const SteamGridDBKindGrid;   // vertical cover, 600x900
extern NSString* const SteamGridDBKindHero;   // wide background
extern NSString* const SteamGridDBKindLogo;   // transparent logo
extern NSString* const SteamGridDBKindIcon;   // square icon
extern NSString* const SteamGridDBKindWide;   // horizontal cover (460x215 / 920x430), logo built in

@interface SteamGridDBManager : NSObject

+ (instancetype)sharedManager;

// Stored in the Keychain. Setting nil or an empty string removes it.
@property (nonatomic, copy, nullable) NSString* apiKey;

- (BOOL)isConfigured;

// Path of a cached artwork file, or nil if it hasn't been downloaded
- (nullable NSString*)cachedPathForAppName:(NSString*)name kind:(NSString*)kind;

// Downloads artwork for the given game names in the background, one game at a time.
// Games already cached (or already known to have no match) are skipped unless force is YES.
// Non-game entries such as "Desktop" are always skipped.
- (void)fetchArtworkForAppNames:(NSArray<NSString*>*)names
                          force:(BOOL)force
                     completion:(nullable void (^)(NSUInteger fetched, NSUInteger notFound, NSUInteger failed))completion;

// Same, with the Steam appid of each game that has one (name -> appid), for exact matches
- (void)fetchArtworkForAppNames:(NSArray<NSString*>*)names
                    steamAppIds:(nullable NSDictionary<NSString*, NSNumber*>*)steamAppIds
                          force:(BOOL)force
                     completion:(nullable void (^)(NSUInteger fetched, NSUInteger notFound, NSUInteger failed))completion;

// Removes all artwork and manual choices
- (void)clearCache;

#pragma mark - Manual artwork choices (completions run on the main queue)

// The SteamGridDB game this name is matched to: @{ @"id", @"name" }, or nil
- (nullable NSDictionary*)matchForAppName:(NSString*)name;

// Searches SteamGridDB games. Results: @[ @{ @"id", @"name", @"year" (may be empty), @"verified" } ], nil on failure
- (void)searchGames:(NSString*)term completion:(void (^)(NSArray<NSDictionary*>* _Nullable results))completion;

// Artwork available for the matched game: @[ @{ @"url", @"thumb" } ], nil on failure
- (void)artworkOptionsForAppName:(NSString*)name kind:(NSString*)kind completion:(void (^)(NSArray<NSDictionary*>* _Nullable options))completion;

// Matches the name to a specific SteamGridDB game (kept for future downloads) and downloads its artwork
- (void)setMatchForAppName:(NSString*)name gameId:(NSString*)gameId gameName:(NSString*)gameName completion:(nullable void (^)(BOOL ok))completion;

// Uses a specific image for one kind (kept for future downloads)
- (void)setArtworkForAppName:(NSString*)name kind:(NSString*)kind url:(NSString*)url completion:(nullable void (^)(BOOL ok))completion;

@end

NS_ASSUME_NONNULL_END
