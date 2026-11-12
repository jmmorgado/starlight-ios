//
//  SteamGridDBManager.h
//  Starlight
//
//  Downloads game artwork (cover, hero, logo, icon) from SteamGridDB and
//  caches it on disk, keyed by the game's name so the same game shares art
//  across PCs. The user's API key is stored on the device, never in code.
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

@interface SteamGridDBManager : NSObject

+ (instancetype)sharedManager;

// Stored in NSUserDefaults. Setting nil or an empty string removes it.
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

- (void)clearCache;

@end

NS_ASSUME_NONNULL_END
