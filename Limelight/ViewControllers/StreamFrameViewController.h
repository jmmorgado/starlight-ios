//
//  StreamFrameViewController.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/18/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Connection.h"
#import "StreamConfiguration.h"
#import "StreamView.h"
#import "TemporarySettings.h"

#import <UIKit/UIKit.h>

#if TARGET_OS_TV
@import GameController;

@interface StreamFrameViewController : GCEventViewController <ConnectionCallbacks, ControllerSupportDelegate, UserInteractionDelegate, UIScrollViewDelegate>
#else
@interface StreamFrameViewController : UIViewController <ConnectionCallbacks, ControllerSupportDelegate, UserInteractionDelegate, UIScrollViewDelegate>
#endif
@property (nonatomic) StreamConfiguration* streamConfig;

-(void)updatePreferredDisplayMode:(BOOL)streamActive;

#if !TARGET_OS_TV
// Starlight: the stream's resolution and frame rate, as if it started now. On the TV (tvScreen set) with
// Match TV Resolution: the TV's (up to 4K, its refresh rate). Otherwise: Stream Settings (clamped to the device)
+ (void)applyResolutionToConfig:(StreamConfiguration*)config settings:(TemporarySettings*)settings tvScreen:(UIScreen*)tvScreen;
#endif

@end
