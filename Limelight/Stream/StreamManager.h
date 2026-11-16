//
//  StreamManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamConfiguration.h"
#import "Connection.h"

@interface StreamManager : NSOperation

- (id) initWithConfig:(StreamConfiguration*)config renderView:(UIView*)view connectionCallbacks:(id<ConnectionCallbacks>)callback;

- (void) stopStream;
// Starlight: stop for a reconnection; completion runs on the main queue once the old connection is gone
- (void) stopStreamWithCompletion:(void (^)(void))completion;

- (NSString*) getStatsOverlayText;

@end
