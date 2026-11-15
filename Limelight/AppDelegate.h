//
//  AppDelegate.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/17/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) NSString *pcUuidToLoad;
@property (strong, nonatomic) void (^shortcutCompletionHandler)(BOOL);

// Deep link launch request: starlight://launch?host=<PC UUID or name>&app=<app ID or name>
@property (strong, nonatomic) NSString *pendingLaunchHost;
@property (strong, nonatomic) NSString *pendingLaunchApp;

@property (readonly, strong, nonatomic) NSManagedObjectContext *managedObjectContext;
@property (readonly, strong, nonatomic) NSManagedObjectModel *managedObjectModel;
@property (readonly, strong, nonatomic) NSPersistentStoreCoordinator *persistentStoreCoordinator;

- (void)saveContext;
- (NSURL *)applicationDocumentsDirectory;
- (NSURL*) getStoreURL;

// Launch requests, also called by StarlightSceneDelegate
- (BOOL)queueLaunchFromURL:(NSURL*)url;
- (BOOL)handleUserActivity:(NSUserActivity*)userActivity;
#if !TARGET_OS_TV
- (void)handleShortcutItem:(UIApplicationShortcutItem*)shortcutItem;

// Starlight: the app turns freely outside a stream; a stream is always landscape
+ (void)setStreamOrientationLocked:(BOOL)locked window:(UIWindow*)window;
#endif

@end

#if !TARGET_OS_TV
// Starlight: the iOS app uses the UIScene life cycle. One scene for the app's window, and one
// for a TV connected by cable or AirPlay (external display, non-interactive), which the stream
// uses when Settings › External Display is set to Second Screen.
extern NSString* const StarlightExternalDisplayDidChangeNotification;

@interface StarlightSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
// The connected TV's scene, or nil
+ (UIWindowScene*)externalDisplayScene;
@end
#endif
