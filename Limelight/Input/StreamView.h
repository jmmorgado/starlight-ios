//
//  StreamView.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "ControllerSupport.h"
#import "OnScreenControls.h"
#import "Moonlight-Swift.h"
#import "StreamConfiguration.h"

@protocol UserInteractionDelegate <NSObject>

- (void) userInteractionBegan;
- (void) userInteractionEnded;

@end

#if TARGET_OS_TV
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate>
#else
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate, UIPointerInteractionDelegate>
#endif

- (void) setupStreamView:(ControllerSupport*)controllerSupport
     interactionDelegate:(id<UserInteractionDelegate>)interactionDelegate
                  config:(StreamConfiguration*)streamConfig;
- (void) showOnScreenControls;
// Starlight: hide the touch controls while the stream is on the TV (Second Screen)
- (void) setOnScreenControlsSuppressed:(BOOL)suppressed;
// Starlight: Touch Mode and On-Screen Controls changed from the stream menu, applied right away
- (void) applyOnScreenControlsLevel:(OnScreenControlsLevel)level absoluteTouch:(BOOL)absoluteTouch;
// Starlight: the stream was reconnected at another resolution
- (void) updateStreamAspectRatio:(float)aspectRatio;
- (OnScreenControlsLevel) getCurrentOscState;
- (void) toggleKeyboard;

#if !TARGET_OS_TV
- (void) updateCursorLocation:(CGPoint)location isMouse:(BOOL)isMouse;
#endif

@end
