//
//  MainFrameViewController.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/17/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "DiscoveryManager.h"
#import "PairManager.h"
#import "StreamConfiguration.h"
#import "UIComputerView.h"
#import "UIAppView.h"
#import "AppAssetManager.h"
#import "SWRevealViewController.h"
#import "TemporarySettings.h"

@interface MainFrameViewController : UICollectionViewController <DiscoveryCallback, PairCallback, HostCallback, AppCallback, AppAssetCallback, NSURLConnectionDelegate, SWRevealViewControllerDelegate>

@property (weak, nonatomic) IBOutlet UIBarButtonItem *settingsButton;
#if !TARGET_OS_TV
@property (weak, nonatomic) IBOutlet UIBarButtonItem *upButton;

// Starlight: quit the game on this PC once the stream screen has closed
- (void)quitAppAfterStreamOnHostAddress:(NSString*)address;

// Starlight: Stream Settings as a dictionary (the keys StreamSettingsView uses), and saving them back
+ (NSDictionary<NSString*, id>*)streamSettingsDictionaryForWindow:(UIWindow*)window;
+ (void)saveStreamSettingsDictionary:(NSDictionary<NSString*, id>*)values;
// Per-PC stream settings: a PC can have its own video and host settings (nil host = every PC).
// The dictionary versions merge the PC's own values over the shared ones; saving writes the PC's
// own values when it has them, the shared ones otherwise.
+ (NSDictionary<NSString*, id>*)streamSettingsDictionaryForWindow:(UIWindow*)window host:(NSString*)hostUUID;
+ (void)saveStreamSettingsDictionary:(NSDictionary<NSString*, id>*)values host:(NSString*)hostUUID;
+ (TemporarySettings*)settingsForHost:(NSString*)hostUUID;
+ (BOOL)hostHasOwnStreamSettings:(NSString*)hostUUID;
#endif

// Starlight: bitrate, frame pacing and video formats (codec, HDR) from Stream Settings; after the resolution is set
+ (void)applyVideoSettings:(TemporarySettings*)settings toConfig:(StreamConfiguration*)config;

@end
