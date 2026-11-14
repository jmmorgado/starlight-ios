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

@interface MainFrameViewController : UICollectionViewController <DiscoveryCallback, PairCallback, HostCallback, AppCallback, AppAssetCallback, NSURLConnectionDelegate, SWRevealViewControllerDelegate>

@property (weak, nonatomic) IBOutlet UIBarButtonItem *settingsButton;
#if !TARGET_OS_TV
@property (weak, nonatomic) IBOutlet UIBarButtonItem *upButton;

// Starlight: quit the game on this PC once the stream screen has closed
- (void)quitAppAfterStreamOnHostAddress:(NSString*)address;

// Starlight: the game's page shown on the device while the stream plays on a TV (nil if the game isn't known)
- (UIViewController*)streamCompanionForHost:(NSString*)hostUUID app:(NSString*)appID onAction:(void (^)(NSString* action))onAction;
#endif

@end
