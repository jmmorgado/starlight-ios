//
//  ControllerSupport.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamConfiguration.h"
#import "Controller.h"

@class OnScreenControls;

@protocol ControllerSupportDelegate <NSObject>

- (void) gamepadPresenceChanged;
- (void) mousePresenceChanged;
- (void) streamExitRequested;

@optional
// Starlight: holding Start toggles the stream menu; while it's open the controller navigates it
- (void) streamMenuRequested;
- (BOOL) streamMenuVisible;
// "up", "down", "select", "back"
- (void) streamMenuNavigate:(NSString*)action;
// While Start is held (menu closed): 0…1 of the hold, so the ••• button can stretch open like a pull;
// cancelled when Start is let go (or used with other buttons) before the menu opens
- (void) streamMenuHoldProgress:(CGFloat)progress;
- (void) streamMenuHoldCancelled;

@end

@interface ControllerSupport : NSObject

-(id) initWithConfig:(StreamConfiguration*)streamConfig delegate:(id<ControllerSupportDelegate>)delegate;
-(void) connectionEstablished;

-(void) initAutoOnScreenControlMode:(OnScreenControls*)osc;
-(void) cleanup;
-(Controller*) getOscController;

-(void) updateLeftStick:(Controller*)controller x:(short)x y:(short)y;
-(void) updateRightStick:(Controller*)controller x:(short)x y:(short)y;

-(void) updateLeftTrigger:(Controller*)controller left:(unsigned char)left;
-(void) updateRightTrigger:(Controller*)controller right:(unsigned char)right;
-(void) updateTriggers:(Controller*)controller left:(unsigned char)left right:(unsigned char)right;

-(void) updateButtonFlags:(Controller*)controller flags:(int)flags;
-(void) setButtonFlag:(Controller*)controller flags:(int)flags;
-(void) clearButtonFlag:(Controller*)controller flags:(int)flags;

-(void) updateFinished:(Controller*)controller;

-(void) rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor;
-(void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger;
-(void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz;
-(void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b;

+(int) getConnectedGamepadMask:(StreamConfiguration*)streamConfig;

-(NSUInteger) getConnectedGamepadCount;

// Starlight: changed from the stream menu's Stream Settings
-(void) setSwapABXYButtons:(BOOL)swap;
-(void) setMultiController:(BOOL)multiController;

@end
