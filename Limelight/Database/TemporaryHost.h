//
//  TemporaryHost.h
//  Moonlight
//
//  Created by Cameron Gutman on 12/1/15.
//  Copyright © 2015 Moonlight Stream. All rights reserved.
//

#import "Utils.h"
#import "Host+CoreDataClass.h"

@interface TemporaryHost : NSObject

@property (atomic) State state;
@property (atomic) PairState pairState;
@property (atomic, nullable, retain) NSString * activeAddress;
@property (atomic, nullable, retain) NSString * currentGame;
// A game another device started on a Vibepollo PC (which reports itself free to
// this device): the id of our copy of it, from the app list. Not stored.
@property (atomic, nullable, retain) NSString * remoteRunningGame;
@property (atomic) unsigned short httpsPort;
@property (atomic) BOOL isNvidiaServerSoftware;

@property (atomic, nullable, retain) NSData *serverCert;
@property (atomic, nullable, retain) NSString *address;
@property (atomic, nullable, retain) NSString *externalAddress;
@property (atomic, nullable, retain) NSString *localAddress;
@property (atomic, nullable, retain) NSString *ipv6Address;
@property (atomic, nullable, retain) NSString *mac;
@property (atomic)                   int serverCodecModeSupport;

NS_ASSUME_NONNULL_BEGIN

@property (atomic, retain) NSString *name;
@property (atomic, retain) NSString *uuid;
@property (atomic, retain) NSSet *appList;

- (id) initFromHost:(Host*)host;

// The running game whichever device started it: currentGame, else remoteRunningGame, else "0"
- (NSString*) runningGame;
// Finds our copy of the game Vibepollo lists as running elsewhere (nil clears it); YES if that changed
- (BOOL) setRemoteRunningGameName:(nullable NSString*)name;

- (NSComparisonResult)compareName:(TemporaryHost *)other;

- (void) propagateChangesToParent:(Host*)host;

NS_ASSUME_NONNULL_END

@end
