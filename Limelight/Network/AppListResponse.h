//
//  AppListResponse.h
//  Moonlight
//
//  Created by Diego Waxemberg on 2/1/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "HttpResponse.h"

@interface AppListResponse : NSObject <Response>

- (void)populateWithData:(NSData *)data;
- (NSSet*) getAppList;
- (BOOL) isStatusOk;

// Vibepollo tells a client that didn't start the running game the host is free,
// and lists a resume-only copy of that game instead: its name, or nil.
- (NSString*) runningGameName;

@end
