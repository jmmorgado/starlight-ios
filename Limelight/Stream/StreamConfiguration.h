//
//  StreamConfiguration.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@interface StreamConfiguration : NSObject

@property NSString* host;
@property unsigned short httpsPort;
@property NSString* appVersion;
@property NSString* gfeVersion;
@property NSString* appID;
@property NSString* appName;
// Starlight: the PC's UUID, used to look up the game's Steam appid during the stream
@property NSString* hostUUID;
// Starlight Handoff: the PC's name and the app's UUID (for the stream activity), and, for a stream
// continued from another device, until when a failed Resume is retried (the other device may still be letting go)
@property NSString* hostName;
@property NSString* appUUID;
@property NSDate* handoffRetryUntil;
// Ask the PC to resume the running game (Rubylight: join another device's game, or after Continue here)
@property BOOL forceResume;
// Rubylight: the PC lets this device manage guests who join its game (feature session.guests)
@property BOOL nativeGuests;
// Rubylight: the PC reports a launcher (Steam…) holding up the game (feature session.launcher)
@property BOOL nativeLauncher;
// Rubylight Join: the name of the device whose game this one asks to join (the start screen says so)
@property NSString* joiningDevice;
@property NSString* rtspSessionUrl;
@property int serverCodecModeSupport;
@property int width;
@property int height;
@property int frameRate;
@property int bitRate;
@property int riKeyId;
@property NSData* riKey;
@property int gamepadMask;
@property BOOL optimizeGameSettings;
@property BOOL playAudioOnPC;
@property BOOL swapABXYButtons;
@property int audioConfiguration;
@property int supportedVideoFormats;
@property BOOL multiController;
@property BOOL useFramePacing;
@property NSData* serverCert;

@end
