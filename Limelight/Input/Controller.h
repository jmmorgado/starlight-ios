//
//  Controller.h
//  Moonlight
//
//  Created by Cameron Gutman on 2/11/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

#import "HapticContext.h"

@import GameController;
@import CoreHaptics;

@interface Controller : NSObject

typedef struct {
    float lastX;
    float lastY;
} controller_touch_context_t;

@property (nullable, nonatomic, retain) GCController* gamepad;
@property (nonatomic)                   int playerIndex;
@property (nonatomic)                   int lastButtonFlags;
@property (nonatomic)                   int emulatingButtonFlags;
@property (nonatomic)                   int supportedEmulationFlags;
@property (nonatomic)                   unsigned char lastLeftTrigger;
@property (nonatomic)                   unsigned char lastRightTrigger;
@property (nonatomic)                   short lastLeftStickX;
@property (nonatomic)                   short lastLeftStickY;
@property (nonatomic)                   short lastRightStickX;
@property (nonatomic)                   short lastRightStickY;

// Starlight: hold Start = stream menu (a tap still reaches the PC), Start+Select tap = Guide; menu navigation state
@property (nonatomic)                   BOOL comboActive;       // Start held alone, waiting to see if it's a hold
@property (nonatomic)                   BOOL comboFired;        // the hold opened/closed the menu
@property (nonatomic)                   NSTimer* _Nullable comboTimer;
@property (nonatomic)                   BOOL guideComboActive;  // Start+Select down together
@property (nonatomic)                   BOOL startPassThrough;  // Start pressed with other buttons: goes to the PC as is
@property (nonatomic)                   BOOL guideTapInProgress;
@property (nonatomic)                   BOOL startTapInProgress;
@property (nonatomic)                   BOOL menuWasVisible;
@property (nonatomic)                   int menuPrevFlags;
@property (nonatomic)                   int menuStickDirection;
@property (nonatomic)                   int menuStickXDirection;

@property (nonatomic)                   controller_touch_context_t primaryTouch;
@property (nonatomic)                   controller_touch_context_t secondaryTouch;

@property (nonatomic)                   HapticContext* _Nullable lowFreqMotor;
@property (nonatomic)                   HapticContext* _Nullable highFreqMotor;
@property (nonatomic)                   HapticContext* _Nullable leftTriggerMotor;
@property (nonatomic)                   HapticContext* _Nullable rightTriggerMotor;

@property (nonatomic)                   NSTimer* _Nullable accelTimer;
@property (nonatomic)                   GCAcceleration lastAccelSample;
@property (nonatomic)                   NSTimer* _Nullable gyroTimer;
@property (nonatomic)                   GCRotationRate lastGyroSample;

@property (nonatomic)                   NSTimer* _Nullable batteryTimer;
@property (nonatomic)                   GCDeviceBatteryState lastBatteryState;
@property (nonatomic)                   float lastBatteryLevel;

@property (nonatomic)                   BOOL reportedArrival;
@property (nonatomic)                   Controller* _Nullable mergedWithController;

@end
