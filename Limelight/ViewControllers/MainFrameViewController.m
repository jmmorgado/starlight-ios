//  MainFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/17/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@import ImageIO;

#import "MainFrameViewController.h"
#import "CryptoManager.h"
#import "HttpManager.h"
#import "Connection.h"
#import "StreamManager.h"
#import "Utils.h"
#import "UIComputerView.h"
#import "UIAppView.h"
#import "DataManager.h"
#import "TemporarySettings.h"
#import "WakeOnLanManager.h"
#import "AppListResponse.h"
#import "ServerInfoResponse.h"
#import "StreamFrameViewController.h"
#import "LoadingFrameViewController.h"
#import "ComputerScrollView.h"
#import "TemporaryApp.h"
#import "IdManager.h"
#import "ConnectionHelper.h"

#if !TARGET_OS_TV
#import "SettingsViewController.h"
#if !TARGET_OS_TV
#import "SteamGridDBManager.h"
#import "Moonlight-Swift.h"
#endif
#else
#import <sys/utsname.h>
#endif

#import <VideoToolbox/VideoToolbox.h>

#include <Limelight.h>

@implementation MainFrameViewController {
    NSOperationQueue* _opQueue;
    TemporaryHost* _selectedHost;
    BOOL _showHiddenApps;
    NSString* _uniqueId;
    NSData* _clientCert;
    DiscoveryManager* _discMan;
    AppAssetManager* _appManager;
    StreamConfiguration* _streamConfig;
    UIAlertController* _pairAlert;
    LoadingFrameViewController* _loadingFrame;
    UIScrollView* hostScrollView;
    FrontViewPosition currentPosition;
    NSArray* _sortedAppList;
    NSCache* _boxArtCache;
    bool _background;
    BOOL _pendingLaunchFallbackScheduled;
    // Auto Wake-on-LAN for pinned games / links / Shortcuts
    BOOL _pendingLaunchWaking;
    UILabel* _launchStatusLabel;
    UIView* _launchOverlay;
#if TARGET_OS_TV
    UITapGestureRecognizer* _menuRecognizer;
#else
    StarlightHomeController* _home;
    NSTimer* _homeRefreshTimer;
    NSString* _homeHostUUID;
    NSString* _pendingQuitHostAddress;
    NSMutableSet<NSString*>* _permissionDeniedHosts;
#endif
}
static NSMutableSet* hostList;

- (void)startPairing:(NSString *)PIN {
    // Needs to be synchronous to ensure the alert is shown before any potential
    // failure callback could be invoked.
    dispatch_sync(dispatch_get_main_queue(), ^{
        self->_pairAlert = [UIAlertController alertControllerWithTitle:@"Pairing"
                                                               message:[NSString stringWithFormat:@"Enter the following PIN on the host machine: %@\n\nIf your host PC is running Sunshine, navigate to the Sunshine web UI to enter the PIN.", PIN]
                                                        preferredStyle:UIAlertControllerStyleAlert];
        [self->_pairAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
            self->_pairAlert = nil;
            [self->_discMan startDiscovery];
            [self hideLoadingFrame: ^{
                [self showHostSelectionView];
            }];
        }]];
        [[self activeViewController] presentViewController:self->_pairAlert animated:YES completion:nil];
    });
}

- (void)displayPairingFailureDialog:(NSString *)message {
    UIAlertController* failedDialog = [UIAlertController alertControllerWithTitle:@"Pairing Failed"
                                                                          message:message
                                                                   preferredStyle:UIAlertControllerStyleAlert];
    [Utils addHelpOptionToDialog:failedDialog];
    [failedDialog addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    
    [_discMan startDiscovery];
    
    [self hideLoadingFrame: ^{
        [self showHostSelectionView];
        [[self activeViewController] presentViewController:failedDialog animated:YES completion:nil];
    }];
}

- (void)pairFailed:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_pairAlert != nil) {
            [self->_pairAlert dismissViewControllerAnimated:YES completion:^{
                [self displayPairingFailureDialog:message];
            }];
            self->_pairAlert = nil;
        }
    });
}

- (void)pairSuccessful:(NSData*)serverCert {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Store the cert from pairing with the host
        self->_selectedHost.serverCert = serverCert;
        
        [self->_pairAlert dismissViewControllerAnimated:YES completion:nil];
        self->_pairAlert = nil;
        
        [self->_discMan startDiscovery];
        [self alreadyPaired];
    });
}

- (void)disableUpButton {
#if !TARGET_OS_TV
    [self->_upButton setTitle:nil];
#endif
}

- (void)enableUpButton {
#if !TARGET_OS_TV
    [self->_upButton setTitle:@"Select New Host"];
#endif
}

- (void)updateTitle {
    if (_selectedHost != nil) {
        self.title = _selectedHost.name;
    }
    else if ([hostList count] == 0) {
        self.title = @"Searching for PCs on your network...";
    }
    else {
        self.title = @"Select Host";
    }
}

- (void)alreadyPaired {
    BOOL usingCachedAppList = false;
    
    // Capture the host here because it can change once we
    // leave the main thread
    TemporaryHost* host = _selectedHost;
    if (host == nil) {
        [self hideLoadingFrame: nil];
        return;
    }
    
    if ([host.appList count] > 0) {
        usingCachedAppList = true;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (host != self->_selectedHost) {
                [self hideLoadingFrame: nil];
                return;
            }
            
            [self updateAppsForHost:host];
            [self hideLoadingFrame: nil];
        });
    }
    Log(LOG_I, @"Using cached app list: %d", usingCachedAppList);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Exempt this host from discovery while handling the applist query
        [self->_discMan pauseDiscoveryForHost:host];
        
        AppListResponse* appListResp = [ConnectionHelper getAppListForHost:host];
        
        [self->_discMan resumeDiscoveryForHost:host];

        if (![appListResp isStatusOk] || [appListResp getAppList] == nil) {
            Log(LOG_W, @"Failed to get applist: %@", appListResp.statusMessage);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (host != self->_selectedHost) {
                    [self hideLoadingFrame: nil];
                    return;
                }
                
                UIAlertController* applistAlert = [UIAlertController alertControllerWithTitle:@"Connection Interrupted"
                                                                                      message:appListResp.statusMessage
                                                                               preferredStyle:UIAlertControllerStyleAlert];
                [Utils addHelpOptionToDialog:applistAlert];
                [applistAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self hideLoadingFrame: ^{
                    [self showHostSelectionView];
                    [[self activeViewController] presentViewController:applistAlert animated:YES completion:nil];
                }];
                host.state = StateOffline;
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateApplist:[appListResp getAppList] forHost:host];

                if (host != self->_selectedHost) {
                    [self hideLoadingFrame: nil];
                    return;
                }
                
                [self updateAppsForHost:host];
                [self->_appManager stopRetrieving];
                [self->_appManager retrieveAssetsFromHost:host];
                [self hideLoadingFrame: nil];
            });
        }
    });
}

- (void) updateAppEntry:(TemporaryApp*)app forHost:(TemporaryHost*)host {
    DataManager* database = [[DataManager alloc] init];
    NSMutableSet* newHostAppList = [NSMutableSet setWithSet:host.appList];

    for (TemporaryApp* savedApp in newHostAppList) {
        if ([app.id isEqualToString:savedApp.id]) {
            savedApp.name = app.name;
            savedApp.hdrSupported = app.hdrSupported;
            savedApp.hidden = app.hidden;
            
            host.appList = newHostAppList;

            [database updateAppsForExistingHost:host];
            return;
        }
    }
}
    
- (void) updateApplist:(NSSet*) newList forHost:(TemporaryHost*)host {
#if !TARGET_OS_TV
    newList = [self starlightFilterAppList:newList forHost:host];
#endif
    DataManager* database = [[DataManager alloc] init];
    NSMutableSet* newHostAppList = [NSMutableSet setWithSet:host.appList];
    
    for (TemporaryApp* app in newList) {
        BOOL appAlreadyInList = NO;
        for (TemporaryApp* savedApp in newHostAppList) {
            if ([app.id isEqualToString:savedApp.id]) {
                savedApp.name = app.name;
                savedApp.hdrSupported = app.hdrSupported;
                // Don't propagate hidden, because we want the local data to prevail
                appAlreadyInList = YES;
                break;
            }
        }
        if (!appAlreadyInList) {
            app.host = host;
            [newHostAppList addObject:app];
        }
    }
    
    BOOL appWasRemoved;
    do {
        appWasRemoved = NO;
        
        for (TemporaryApp* app in newHostAppList) {
            appWasRemoved = YES;
            for (TemporaryApp* mergedApp in newList) {
                if ([mergedApp.id isEqualToString:app.id]) {
                    appWasRemoved = NO;
                    break;
                }
            }
            if (appWasRemoved) {
                // Removing the app mutates the list we're iterating (which isn't legal).
                // We need to jump out of this loop and restart enumeration.
                
                [newHostAppList removeObject:app];
                
                // It's important to remove the app record from the database
                // since we'll have a constraint violation now that appList
                // doesn't have this app in it.
                [database removeApp:app];
                
                break;
            }
        }
        
        // Keep looping until the list is no longer being mutated
    } while (appWasRemoved);
    
    host.appList = newHostAppList;

    [database updateAppsForExistingHost:host];
    
    // This host may be eligible for a shortcut now that the app list
    // has been populated
    [self updateHostShortcuts];
    
#if !TARGET_OS_TV
    // Download SteamGridDB artwork for any games that don't have it yet
    [self fetchArtworkForHosts:@[host] force:NO completion:nil];
#endif
}

- (void)showHostSelectionView {
#if TARGET_OS_TV
    // Remove the menu button intercept to allow the app to exit
    // when at the host selection view.
    [self.navigationController.view removeGestureRecognizer:_menuRecognizer];
#endif
    
    [_appManager stopRetrieving];
    _showHiddenApps = NO;
    _selectedHost = nil;
    _sortedAppList = nil;
    
    [self updateTitle];
    [self disableUpButton];
    
    [self.collectionView reloadData];
    [self.view addSubview:hostScrollView];
}

- (void) receivedAssetForApp:(TemporaryApp*)app {
    // Update the box art cache now so we don't have to do it
    // on the main thread
    [self updateBoxArtCacheForApp:app];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.collectionView reloadData];
    });
}

- (void)displayDnsFailedDialog {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Network Error"
                                                                   message:@"Failed to resolve host."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [Utils addHelpOptionToDialog:alert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self activeViewController] presentViewController:alert animated:YES completion:nil];
}

- (void) hostClicked:(TemporaryHost *)host view:(UIView *)view {
    // Treat clicks on offline hosts to be long clicks
    // This shows the context menu with wake, delete, etc. rather
    // than just hanging for a while and failing as we would in this
    // code path.
    if (host.state != StateOnline && view != nil) {
        [self hostLongClicked:host view:view];
        return;
    }
    
    Log(LOG_D, @"Clicked host: %@", host.name);
    _selectedHost = host;
    [self updateTitle];
    [self enableUpButton];
    [self disableNavigation];
    
#if TARGET_OS_TV
    // Intercept the menu key to go back to the host page
    [self.navigationController.view addGestureRecognizer:_menuRecognizer];
#endif
    
    // If we are online, paired, and have a cached app list, skip straight
    // to the app grid without a loading frame. This is the fast path that users
    // should hit most. Check for a valid view because we don't want to hit the fast
    // path after coming back from streaming, since we need to fetch serverinfo too
    // so that our active game data is correct.
    if (host.state == StateOnline && host.pairState == PairStatePaired && host.appList.count > 0 && view != nil) {
        [self alreadyPaired];
        return;
    }
    
    [self showLoadingFrame: ^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // Wait for the PC's status to be known
            while (host.state == StateUnknown) {
                sleep(1);
            }
            
            // Don't bother polling if the server is already offline
            if (host.state == StateOffline) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self hideLoadingFrame:^{
                        [self showHostSelectionView];
                    }];
                });
                return;
            }
            
            HttpManager* hMan = [[HttpManager alloc] initWithHost:host];
            ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
            
            // Exempt this host from discovery while handling the serverinfo request
            [self->_discMan pauseDiscoveryForHost:host];
            [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:false]
                                                                fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
            [self->_discMan resumeDiscoveryForHost:host];
            
            if (![serverInfoResp isStatusOk]) {
                Log(LOG_W, @"Failed to get server info: %@", serverInfoResp.statusMessage);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (host != self->_selectedHost) {
                        [self hideLoadingFrame:nil];
                        return;
                    }
                    
                    UIAlertController* applistAlert = [UIAlertController alertControllerWithTitle:@"Connection Failed"
                                                                            message:serverInfoResp.statusMessage
                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                    [Utils addHelpOptionToDialog:applistAlert];
                    [applistAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    
                    // Only display an alert if this was the result of a real
                    // user action, not just passively entering the foreground again
                    [self hideLoadingFrame: ^{
                        [self showHostSelectionView];
                        if (view != nil) {
                            [[self activeViewController] presentViewController:applistAlert animated:YES completion:nil];
                        }
                    }];
                    
                    host.state = StateOffline;
                });
            } else {
                // Update the host object with this data
                [serverInfoResp populateHost:host];
                if (host.pairState == PairStatePaired) {
                    Log(LOG_I, @"Already Paired");
                    [self alreadyPaired];
                }
                // Only pair when this was the result of explicit user action
                else if (view != nil) {
                    Log(LOG_I, @"Trying to pair");
                    // Polling the server while pairing causes the server to screw up
                    [self->_discMan stopDiscoveryBlocking];
                    PairManager* pMan = [[PairManager alloc] initWithManager:hMan clientCert:self->_clientCert callback:self];
                    [self->_opQueue addOperation:pMan];
                }
                else {
                    // Not user action, so just return to host screen
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self hideLoadingFrame:^{
                            [self showHostSelectionView];
                        }];
                    });
                }
            }
        });
    }];
}

- (UIViewController*) activeViewController {
    UIViewController *topController = [UIApplication sharedApplication].keyWindow.rootViewController;

    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }

    return topController;
}

- (void)hostLongClicked:(TemporaryHost *)host view:(UIView *)view {
    Log(LOG_D, @"Long clicked host: %@", host.name);
    NSString* message;
    
    switch (host.state) {
        case StateOffline:
            message = @"Offline";
            break;
            
        case StateOnline:
            if (host.pairState == PairStatePaired) {
                message = @"Online - Paired";
            }
            else {
                message = @"Online - Not Paired";
            }
            break;
        
        case StateUnknown:
            message = @"Connecting";
            break;
            
        default:
            break;
    }
    
    UIAlertController* longClickAlert = [UIAlertController alertControllerWithTitle:host.name message:message preferredStyle:UIAlertControllerStyleActionSheet];
    if (host.state != StateOnline) {
        [longClickAlert addAction:[UIAlertAction actionWithTitle:@"Wake PC" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            UIAlertController* wolAlert = [UIAlertController alertControllerWithTitle:@"Wake-On-LAN" message:@"" preferredStyle:UIAlertControllerStyleAlert];
            [wolAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            if (host.mac == nil || [host.mac isEqualToString:@"00:00:00:00:00:00"]) {
                wolAlert.message = @"Host MAC unknown, unable to send WOL Packet";
            } else {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [WakeOnLanManager wakeHost:host];
                });
                wolAlert.message = @"Successfully sent wake-up request. It may take a few moments for the PC to wake. If it never wakes up, ensure it's properly configured for Wake-on-LAN.";
            }
            [[self activeViewController] presentViewController:wolAlert animated:YES completion:nil];
        }]];
    }
    else if (host.pairState == PairStatePaired) {
        [longClickAlert addAction:[UIAlertAction actionWithTitle:@"View All Apps" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            self->_showHiddenApps = YES;
            [self hostClicked:host view:view];
        }]];
        
#if !TARGET_OS_TV
        if (host.isNvidiaServerSoftware) {
            [longClickAlert addAction:[UIAlertAction actionWithTitle:@"NVIDIA GameStream End-of-Service" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
                [Utils launchUrl:@"https://github.com/moonlight-stream/moonlight-docs/wiki/NVIDIA-GameStream-End-Of-Service-Announcement-FAQ"];
            }]];
        }
#endif
    }
    [longClickAlert addAction:[UIAlertAction actionWithTitle:@"Test Network" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [self showLoadingFrame:^{
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                // Perform the network test on a GCD worker thread. It may take a while.
                unsigned int portTestResult = LiTestClientConnectivity(CONN_TEST_SERVER, 443, ML_PORT_FLAG_ALL);
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [self hideLoadingFrame:^{
                        NSString* message;
                        
                        if (portTestResult == 0) {
                            message = @"This network does not appear to be blocking Moonlight. If you still have trouble connecting, check your PC's firewall settings.\n\nVisit the Moonlight Setup Guide on GitHub for additional setup help and troubleshooting steps.";
                        }
                        else if (portTestResult == ML_TEST_RESULT_INCONCLUSIVE) {
                            message = @"The network test could not be performed because none of Moonlight's connection testing servers were reachable. Check your Internet connection or try again later.";
                        }
                        else {
                            char blockedPorts[512];
                            LiStringifyPortFlags(portTestResult, "\n", blockedPorts, sizeof(blockedPorts));
                            message = [NSString stringWithFormat:@"Your current network connection seems to be blocking Moonlight. Streaming may not work while connected to this network.\n\nThe following network ports were blocked:\n%s", blockedPorts];
                        }
                        
                        UIAlertController* netTestAlert = [UIAlertController alertControllerWithTitle:@"Network Test Complete" message:message preferredStyle:UIAlertControllerStyleAlert];
                        [netTestAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        [[self activeViewController] presentViewController:netTestAlert animated:YES completion:nil];
                    }];
                });
            });
        }];
    }]];
#if !TARGET_OS_TV
    if (host.state != StateOnline) {
        [longClickAlert addAction:[UIAlertAction actionWithTitle:@"NVIDIA GameStream End-of-Service" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [Utils launchUrl:@"https://github.com/moonlight-stream/moonlight-docs/wiki/NVIDIA-GameStream-End-Of-Service-Announcement-FAQ"];
        }]];
        [longClickAlert addAction:[UIAlertAction actionWithTitle:@"Connection Help" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [Utils launchUrl:@"https://github.com/moonlight-stream/moonlight-docs/wiki/Troubleshooting"];
        }]];
    }
#endif
    [longClickAlert addAction:[UIAlertAction actionWithTitle:@"Remove Host" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
        [self->_discMan removeHostFromDiscovery:host];
        DataManager* dataMan = [[DataManager alloc] init];
        [dataMan removeHost:host];
        @synchronized(hostList) {
            [hostList removeObject:host];
            [self updateAllHosts:[hostList allObjects]];
        }
        
    }]];
    [longClickAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    // these two lines are required for iPad support of UIAlertSheet
    longClickAlert.popoverPresentationController.sourceView = view;
    
    longClickAlert.popoverPresentationController.sourceRect = CGRectMake(view.bounds.size.width / 2.0, view.bounds.size.height / 2.0, 1.0, 1.0); // center of the view
    [[self activeViewController] presentViewController:longClickAlert animated:YES completion:nil];
}

- (void) addHostClicked {
    Log(LOG_D, @"Clicked add host");
    UIAlertController* alertController = [UIAlertController alertControllerWithTitle:@"Add Host Manually" message:@"If Moonlight doesn't find your local gaming PC automatically,\nenter the IP address of your PC" preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
        NSString* hostAddress = [((UITextField*)[[alertController textFields] objectAtIndex:0]).text trim];
        [self showLoadingFrame:^{
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                [self->_discMan discoverHost:hostAddress withCallback:^(TemporaryHost* host, NSString* error){
                    if (host != nil) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self hideLoadingFrame:^{
                                @synchronized(hostList) {
                                    [hostList addObject:host];
                                }
                                [self updateHosts];
                            }];
                        });
                    } else {
                        unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443,
                                                                                ML_PORT_FLAG_TCP_47984 | ML_PORT_FLAG_TCP_47989);
                        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
                            error = [error stringByAppendingString:@"\n\nYour device's network connection is blocking Moonlight. Streaming may not work while connected to this network."];
                        }
                        
                        UIAlertController* hostNotFoundAlert = [UIAlertController alertControllerWithTitle:@"Add Host Manually" message:error preferredStyle:UIAlertControllerStyleAlert];
                        [Utils addHelpOptionToDialog:hostNotFoundAlert];
                        [hostNotFoundAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self hideLoadingFrame:^{
                                [[self activeViewController] presentViewController:hostNotFoundAlert animated:YES completion:nil];
                            }];
                        });
                    }
                }];
            });
        }];
    }]];
    [alertController addTextFieldWithConfigurationHandler:nil];
    [[self activeViewController] presentViewController:alertController animated:YES completion:nil];
}

- (void) prepareToStreamApp:(TemporaryApp *)app {
#if !TARGET_OS_TV
    [self recordLastPlayedForApp:app];
#endif
    _streamConfig = [[StreamConfiguration alloc] init];
    _streamConfig.host = app.host.activeAddress;
    _streamConfig.httpsPort = app.host.httpsPort;
    _streamConfig.appID = app.id;
    _streamConfig.appName = app.name;
    _streamConfig.serverCert = app.host.serverCert;
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    
    _streamConfig.frameRate = [streamSettings.framerate intValue];
    if (@available(iOS 10.3, *)) {
        // Don't stream more FPS than the display can show
        if (_streamConfig.frameRate > [UIScreen mainScreen].maximumFramesPerSecond) {
            _streamConfig.frameRate = (int)[UIScreen mainScreen].maximumFramesPerSecond;
            Log(LOG_W, @"Clamping FPS to maximum refresh rate: %d", _streamConfig.frameRate);
        }
    }
    
    _streamConfig.height = [streamSettings.height intValue];
    _streamConfig.width = [streamSettings.width intValue];
#if TARGET_OS_TV
    // Don't allow streaming 4K on the Apple TV HD
    struct utsname systemInfo;
    uname(&systemInfo);
    if (strcmp(systemInfo.machine, "AppleTV5,3") == 0 && _streamConfig.height >= 2160) {
        Log(LOG_W, @"4K streaming not supported on Apple TV HD");
        _streamConfig.width = 1920;
        _streamConfig.height = 1080;
    }
#endif
    
    _streamConfig.bitRate = [streamSettings.bitrate intValue];
    _streamConfig.optimizeGameSettings = streamSettings.optimizeGames;
    _streamConfig.playAudioOnPC = streamSettings.playAudioOnPC;
    _streamConfig.useFramePacing = streamSettings.useFramePacing;
    _streamConfig.swapABXYButtons = streamSettings.swapABXYButtons;
    
    // multiController must be set before calling getConnectedGamepadMask
    _streamConfig.multiController = streamSettings.multiController;
    _streamConfig.gamepadMask = [ControllerSupport getConnectedGamepadMask:_streamConfig];
    
    // Probe for supported channel configurations
    int physicalOutputChannels = (int)[AVAudioSession sharedInstance].maximumOutputNumberOfChannels;
    Log(LOG_I, @"Audio device supports %d channels", physicalOutputChannels);
    
    int numberOfChannels = MIN([streamSettings.audioConfig intValue], physicalOutputChannels);
    Log(LOG_I, @"Selected number of audio channels %d", numberOfChannels);
    if (numberOfChannels >= 8) {
        _streamConfig.audioConfiguration = AUDIO_CONFIGURATION_71_SURROUND;
    }
    else if (numberOfChannels >= 6) {
        _streamConfig.audioConfiguration = AUDIO_CONFIGURATION_51_SURROUND;
    }
    else {
        _streamConfig.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    }
    
    _streamConfig.serverCodecModeSupport = app.host.serverCodecModeSupport;
    
    switch (streamSettings.preferredCodec) {
        case CODEC_PREF_AV1:
#if defined(__IPHONE_16_0) || defined(__TVOS_16_0)
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
                _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN8;
            }
#endif
            // Fall-through
            
        case CODEC_PREF_AUTO:
        case CODEC_PREF_HEVC:
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
                _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265;
            }
            // Fall-through
            
        case CODEC_PREF_H264:
            _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H264;
            break;
    }
    
    // HEVC is supported if the user wants it (or it's required by the chosen resolution) and the SoC supports it
    if ((_streamConfig.width > 4096 || _streamConfig.height > 4096 || streamSettings.enableHdr) && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265;
        
        // HEVC Main10 is supported if the user wants it and the display supports it
        if (streamSettings.enableHdr && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0) {
            _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265_MAIN10;
        }
    }
    
#if defined(__IPHONE_16_0) || defined(__TVOS_16_0)
    // Add the AV1 Main10 format if AV1 and HDR are both enabled and supported
    if ((_streamConfig.supportedVideoFormats & VIDEO_FORMAT_MASK_AV1) && streamSettings.enableHdr &&
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0) {
        _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN10;
    }
#endif
}

- (void)appLongClicked:(TemporaryApp *)app view:(UIView *)view {
    Log(LOG_D, @"Long clicked app: %@", app.name);
    
    [_appManager stopRetrieving];
    
#if !TARGET_OS_TV
    if (currentPosition != FrontViewPositionLeft) {
        // This must not be animated because we need the position
        // to change (and notify our callback to save settings data)
        // before we call prepareToStreamApp.
        [[self revealViewController] revealToggleAnimated:NO];
    }
#endif

    TemporaryApp* currentApp = [self findRunningApp:app.host];
    
    NSString* message;
    
    if (currentApp == nil || [app.id isEqualToString:currentApp.id]) {
        if (app.hidden) {
            message = @"Hidden";
        }
        else {
            message = @"";
        }
    }
    else {
        message = [NSString stringWithFormat:@"%@ is currently running", currentApp.name];
    }
    
    UIAlertController* alertController = [UIAlertController
                                          alertControllerWithTitle: app.name
                                          message:message
                                          preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alertController addAction:[UIAlertAction
                                actionWithTitle:currentApp == nil ? @"Launch App" : ([app.id isEqualToString:currentApp.id] ? @"Resume App" : @"Resume Running App") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
        if (currentApp != nil) {
            Log(LOG_I, @"Resuming application: %@", currentApp.name);
            [self prepareToStreamApp:currentApp];
        }
        else {
            Log(LOG_I, @"Launching application: %@", app.name);
            [self prepareToStreamApp:app];
        }

        [self performSegueWithIdentifier:@"createStreamFrame" sender:nil];
    }]];
    
    if (currentApp != nil) {
        [alertController addAction:[UIAlertAction actionWithTitle:
                                    [app.id isEqualToString:currentApp.id] ? @"Quit App" : @"Quit Running App and Start" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action){
                                        Log(LOG_I, @"Quitting application: %@", currentApp.name);
                                        [self showLoadingFrame: ^{
                                            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                                HttpManager* hMan = [[HttpManager alloc] initWithHost:app.host];
                                                HttpResponse* quitResponse = [[HttpResponse alloc] init];
                                                HttpRequest* quitRequest = [HttpRequest requestForResponse: quitResponse withUrlRequest:[hMan newQuitAppRequest]];
                                                
                                                // Exempt this host from discovery while handling the quit operation
                                                [self->_discMan pauseDiscoveryForHost:app.host];
                                                [hMan executeRequestSynchronously:quitRequest];
                                                if (quitResponse.statusCode == 200) {
                                                    ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
                                                    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:false]
                                                                                                        fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
                                                    if (![serverInfoResp isStatusOk] || [[serverInfoResp getStringTag:@"state"] hasSuffix:@"_SERVER_BUSY"]) {
                                                        // On newer GFE versions, the quit request succeeds even though the app doesn't
                                                        // really quit if another client tries to kill your app. We'll patch the response
                                                        // to look like the old error in that case, so the UI behaves.
                                                        quitResponse.statusCode = 599;
                                                    }
                                                    else if ([serverInfoResp isStatusOk]) {
                                                        // Update the host object with this info
                                                        [serverInfoResp populateHost:app.host];
                                                    }
                                                }
                                                [self->_discMan resumeDiscoveryForHost:app.host];

                                                // If it fails, display an error and stop the current operation
                                                if (quitResponse.statusCode != 200) {
                                                    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Quitting App Failed"
                                                                                                message:@"Failed to quit app. If this app was started by "
                                                             "another device, you'll need to quit from that device."
                                                                                         preferredStyle:UIAlertControllerStyleAlert];
                                                    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                                                    dispatch_async(dispatch_get_main_queue(), ^{
                                                        [self updateAppsForHost:app.host];
                                                        [self hideLoadingFrame: ^{
                                                            [[self activeViewController] presentViewController:alert animated:YES completion:nil];
                                                        }];
                                                    });
                                                }
                                                else {
                                                    app.host.currentGame = @"0";
                                                    dispatch_async(dispatch_get_main_queue(), ^{
                                                        // If it succeeds and we're to start streaming, segue to the stream
                                                        if (![app.id isEqualToString:currentApp.id]) {
                                                            [self prepareToStreamApp:app];
                                                            [self hideLoadingFrame: ^{
                                                                [self performSegueWithIdentifier:@"createStreamFrame" sender:nil];
                                                            }];
                                                        }
                                                        else {
                                                            // Otherwise, just hide the loading icon
                                                            [self hideLoadingFrame:nil];
                                                        }
                                                    });
                                                }
                                            });
                                        }];
                                        
                                    }]];
    }

    if (currentApp == nil || ![app.id isEqualToString:currentApp.id] || app.hidden) {
        [alertController addAction:[UIAlertAction actionWithTitle:app.hidden ? @"Show App" : @"Hide App"
                                                            style:app.hidden ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive
                                                          handler:^(UIAlertAction* action) {
            app.hidden = !app.hidden;
            [self updateAppEntry:app forHost:app.host];
            
            // Don't call updateAppsForHost because that will nuke this
            // app immediately if we're not showing hidden apps.
        }]];
    }
    
#if !TARGET_OS_TV
    // Pins the game to the app icon's long-press menu for one-tap launches
    [alertController addAction:[UIAlertAction actionWithTitle:([self isAppPinned:app] ? @"Unpin from App Icon" : @"Pin to App Icon") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [self togglePinForApp:app];
    }]];
    
    // Saves a square icon of the game's art to Photos, for Shortcuts Home Screen icons
    [alertController addAction:[UIAlertAction actionWithTitle:@"Save Icon to Photos" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [self saveIconToPhotosForApp:app];
    }]];
    
    // Copies a starlight:// URL that launches this app directly (for the Shortcuts app)
    [alertController addAction:[UIAlertAction actionWithTitle:@"Copy Shortcut Link" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        NSString* link = [self launchLinkForApp:app];
        [UIPasteboard generalPasteboard].string = link;

        UIAlertController* copiedAlert = [UIAlertController alertControllerWithTitle:@"Shortcut Link Copied"
                                                                             message:[NSString stringWithFormat:@"In the Shortcuts app, add an \"Open URLs\" action and paste this link:\n\n%@", link]
                                                                      preferredStyle:UIAlertControllerStyleAlert];
        [copiedAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [[self activeViewController] presentViewController:copiedAlert animated:YES completion:nil];
    }]];
#endif

    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    // these two lines are required for iPad support of UIAlertSheet
    alertController.popoverPresentationController.sourceView = view;
    
    alertController.popoverPresentationController.sourceRect = CGRectMake(view.bounds.size.width / 2.0, view.bounds.size.height / 2.0, 1.0, 1.0); // center of the view
    [[self activeViewController] presentViewController:alertController animated:YES completion:nil];
}

- (void) appClicked:(TemporaryApp *)app view:(UIView *)view {
    Log(LOG_D, @"Clicked app: %@", app.name);
    
    [_appManager stopRetrieving];
    
#if !TARGET_OS_TV
    if (currentPosition != FrontViewPositionLeft) {
        // This must not be animated because we need the position
        // to change (and notify our callback to save settings data)
        // before we call prepareToStreamApp.
        [[self revealViewController] revealToggleAnimated:NO];
    }
#endif
    
    if ([self findRunningApp:app.host]) {
        // If there's a running app, display a menu
        [self appLongClicked:app view:view];
    } else {
        [self prepareToStreamApp:app];
        [self performSegueWithIdentifier:@"createStreamFrame" sender:nil];
    }
}

- (TemporaryApp*) findRunningApp:(TemporaryHost*)host {
    for (TemporaryApp* app in host.appList) {
        if ([app.id isEqualToString:host.currentGame]) {
            return app;
        }
    }
    return nil;
}

#if !TARGET_OS_TV
- (void)revealController:(SWRevealViewController *)revealController didMoveToPosition:(FrontViewPosition)position {
    // If we moved back to the center position, we should save the settings
    if (position == FrontViewPositionLeft) {
        [(SettingsViewController*)[revealController rearViewController] saveSettings];
    }
    
    currentPosition = position;
}
#endif

#if TARGET_OS_TV
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [self appClicked:_sortedAppList[indexPath.row] view:nil];
}
#endif

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.destinationViewController isKindOfClass:[StreamFrameViewController class]]) {
        StreamFrameViewController* streamFrame = segue.destinationViewController;
        streamFrame.streamConfig = _streamConfig;
    }
}

- (void) showLoadingFrame:(void (^)(void))completion {
    [_loadingFrame showLoadingFrame:completion];
}

- (void) hideLoadingFrame:(void (^)(void))completion {
    [self enableNavigation];
    [_loadingFrame dismissLoadingFrame:completion];
}

- (void)adjustScrollViewForSafeArea:(UIScrollView*)view {
    if (@available(iOS 11.0, *)) {
        if (self.view.safeAreaInsets.left >= 20 || self.view.safeAreaInsets.right >= 20) {
            view.contentInset = UIEdgeInsetsMake(0, 20, 0, 20);
        }
    }
}

// Adjust the subviews for the safe area on the iPhone X.
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    
    [self adjustScrollViewForSafeArea:self.collectionView];
    [self adjustScrollViewForSafeArea:self->hostScrollView];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    // Launched from a pinned game or starlight:// link: never show the main screen
    AppDelegate* launchDelegate = (AppDelegate*)[UIApplication sharedApplication].delegate;
    if (launchDelegate.pendingLaunchHost != nil && launchDelegate.pendingLaunchApp != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* delegate = (AppDelegate*)[UIApplication sharedApplication].delegate;
            if (delegate.pendingLaunchHost != nil && self->_launchOverlay == nil) {
                [self showLaunchOverlayForApp:nil];
            }
        });
    }
    
#if !TARGET_OS_TV
    // Starlight UI (SwiftUI) on top of the Moonlight view controller, which keeps
    // doing discovery, pairing and streaming underneath
    [self installHomeIfNeeded];
#endif
        
#if !TARGET_OS_TV
    // Set the side bar button action. When it's tapped, it'll show the sidebar.
    [_settingsButton setTarget:self.revealViewController];
    [_settingsButton setAction:@selector(revealToggle:)];
    
    // Set the host name button action. When it's tapped, it'll show the host selection view.
    [_upButton setTarget:self];
    [_upButton setAction:@selector(showHostSelectionView)];
    [self disableUpButton];
    
    // Set the gesture
    if (_home == nil) {
        [self.view addGestureRecognizer:self.revealViewController.panGestureRecognizer];
    }
    
    // Get callbacks associated with the viewController
    [self.revealViewController setDelegate:self];
    
    // Disable bounce-back on reveal VC otherwise the settings will snap closed
    // if the user drags all the way off the screen opposite the settings pane.
    self.revealViewController.bounceBackOnOverdraw = NO;
#else
    // The settings button will direct the user into the Settings app on tvOS
    [_settingsButton setTarget:self];
    [_settingsButton setAction:@selector(openTvSettings:)];
    
    // Restore focus on the selected app on view controller pop navigation
    self.restoresFocusAfterTransition = NO;
    self.collectionView.remembersLastFocusedIndexPath = YES;
    
    _menuRecognizer = [[UITapGestureRecognizer alloc] init];
    [_menuRecognizer addTarget:self action: @selector(showHostSelectionView)];
    _menuRecognizer.allowedPressTypes = [[NSArray alloc] initWithObjects:[NSNumber numberWithLong:UIPressTypeMenu], nil];
    
    self.navigationController.navigationBar.titleTextAttributes = [NSDictionary dictionaryWithObject:[UIColor whiteColor] forKey:NSForegroundColorAttributeName];
#endif
    
    _loadingFrame = [self.storyboard instantiateViewControllerWithIdentifier:@"loadingFrame"];
    
    // Set the current position to the center
    currentPosition = FrontViewPositionLeft;
    
    // Set up crypto
    [CryptoManager generateKeyPairUsingSSL];
    _uniqueId = [IdManager getUniqueId];
    _clientCert = [CryptoManager readCertFromFile];

    _appManager = [[AppAssetManager alloc] initWithCallback:self];
    _opQueue = [[NSOperationQueue alloc] init];
    
    // Only initialize the host picker list once
    if (hostList == nil) {
        hostList = [[NSMutableSet alloc] init];
    }
    
    _boxArtCache = [[NSCache alloc] init];
        
    hostScrollView = [[ComputerScrollView alloc] init];
    hostScrollView.frame = CGRectMake(0, self.navigationController.navigationBar.frame.origin.y + self.navigationController.navigationBar.frame.size.height, self.view.frame.size.width, self.view.frame.size.height / 2);
    [hostScrollView setShowsHorizontalScrollIndicator:NO];
    hostScrollView.delaysContentTouches = NO;
    
    self.collectionView.delaysContentTouches = NO;
    self.collectionView.allowsMultipleSelection = NO;
#if !TARGET_OS_TV
    self.collectionView.multipleTouchEnabled = NO;
#else
    // This is the only way to get long press events on a UICollectionViewCell :(
    UILongPressGestureRecognizer* cellLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleCollectionViewLongPress:)];
    cellLongPress.delaysTouchesBegan = YES;
    [self.collectionView addGestureRecognizer:cellLongPress];
#endif
    
    [self retrieveSavedHosts];
    _discMan = [[DiscoveryManager alloc] initWithHosts:[hostList allObjects] andCallback:self];
        
    if ([hostList count] == 1) {
        [self hostClicked:[hostList anyObject] view:nil];
    }
    else {
        [self updateTitle];
        [self.view addSubview:hostScrollView];
    }
}

#if TARGET_OS_TV
-(void)handleCollectionViewLongPress:(UILongPressGestureRecognizer *)gestureRecognizer
{
    // FIXME: Something is delaying touches so we only get to the Begin state
    // before we actually want to signal the long press.
    if (gestureRecognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }
    
    CGPoint point = [gestureRecognizer locationInView:self.collectionView];
    NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:point];
    if (indexPath != nil) {
        [self appLongClicked:_sortedAppList[indexPath.row] view:nil];
    }
}

- (void)openTvSettings:(id)sender
{
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
}
#endif

-(void)beginForegroundRefresh
{
    if (!_background) {
        // This will kick off box art caching
        [self updateHosts];
        
        // Reset state first so we can rediscover hosts that were deleted before
        [_discMan resetDiscoveryState];
        [_discMan startDiscovery];
        
        // This will refresh the applist when a paired host is selected
        if (_selectedHost != nil && _selectedHost.pairState == PairStatePaired) {
            [self hostClicked:_selectedHost view:nil];
        }
    }
}

-(void)handlePendingShortcutAction
{
    // Check if we have a pending shortcut action
    AppDelegate* delegate = (AppDelegate*)[UIApplication sharedApplication].delegate;
    if (delegate.pcUuidToLoad != nil) {
        // Find the host it corresponds to
        TemporaryHost* matchingHost = nil;
        for (TemporaryHost* host in hostList) {
            if ([host.uuid isEqualToString:delegate.pcUuidToLoad]) {
                matchingHost = host;
                break;
            }
        }
        
        // Clear the pending shortcut action
        delegate.pcUuidToLoad = nil;
        
        // Complete the request
        if (delegate.shortcutCompletionHandler != nil) {
            delegate.shortcutCompletionHandler(matchingHost != nil);
            delegate.shortcutCompletionHandler = nil;
        }
        
        if (matchingHost != nil && _selectedHost != matchingHost) {
            // Navigate to the host page
            [self hostClicked:matchingHost view:nil];
        }
    }
}

#pragma mark - Deep link launch (starlight://launch?host=...&app=...)

- (NSString*)launchLinkForApp:(TemporaryApp*)app {
    NSURLComponents* components = [[NSURLComponents alloc] init];
    components.scheme = @"starlight";
    components.host = @"launch";
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"host" value:app.host.uuid],
                              [NSURLQueryItem queryItemWithName:@"app" value:app.id],
                              // Informational only, makes links readable in Shortcuts
                              [NSURLQueryItem queryItemWithName:@"name" value:app.name]];
    return components.URL.absoluteString;
}

- (void)clearPendingLaunch {
    AppDelegate* delegate = (AppDelegate*)[UIApplication sharedApplication].delegate;
    delegate.pendingLaunchHost = nil;
    delegate.pendingLaunchApp = nil;
    _pendingLaunchFallbackScheduled = NO;
    _pendingLaunchWaking = NO;
}

// Settings → Launching → Wake PC Automatically (on unless turned off)
- (BOOL)autoWakeEnabled {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:@"StarlightAutoWake"];
    return value == nil || [value boolValue];
}

- (BOOL)canWakeHost:(TemporaryHost*)host {
    return host.mac != nil && ![host.mac isEqualToString:@"00:00:00:00:00:00"];
}

- (void)sendWakeToHost:(TemporaryHost*)host {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [WakeOnLanManager wakeHost:host];
    });
}

- (void)showPendingLaunchError:(NSString*)message {
    [self hideLaunchOverlay];
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Shortcut Launch Failed"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self activeViewController] presentViewController:alert animated:YES completion:nil];
}

// Launches the app requested by a deep link once this view is visible.
// If the host hasn't been found online yet, waits for discovery for a few
// seconds before trying with the last known address.
- (void)handlePendingLaunch:(BOOL)force {
    AppDelegate* delegate = (AppDelegate*)[UIApplication sharedApplication].delegate;
    NSString* hostParam = delegate.pendingLaunchHost;
    NSString* appParam = delegate.pendingLaunchApp;
    if (hostParam == nil || appParam == nil) {
        return;
    }

    // Only act while we're the visible view (not streaming, not backgrounded)
    if (_background || self.view.window == nil) {
        // Allow the wait to restart when we become visible again
        _pendingLaunchFallbackScheduled = NO;
        return;
    }

    TemporaryHost* host = nil;
    @synchronized (hostList) {
        for (TemporaryHost* candidate in hostList) {
            if ([candidate.uuid caseInsensitiveCompare:hostParam] == NSOrderedSame) {
                host = candidate;
                break;
            }
        }
        if (host == nil) {
            for (TemporaryHost* candidate in hostList) {
                if ([candidate.name caseInsensitiveCompare:hostParam] == NSOrderedSame) {
                    host = candidate;
                    break;
                }
            }
        }
    }

    if (host == nil) {
        [self clearPendingLaunch];
        [self showPendingLaunchError:[NSString stringWithFormat:@"No paired PC matches \"%@\". Add and pair the PC in Starlight first.", hostParam]];
        return;
    }

    if (host.pairState != PairStatePaired && host.serverCert == nil) {
        [self clearPendingLaunch];
        [self showPendingLaunchError:[NSString stringWithFormat:@"%@ is not paired with this device.", host.name]];
        return;
    }

    TemporaryApp* app = nil;
    for (TemporaryApp* candidate in host.appList) {
        if ([candidate.id isEqualToString:appParam]) {
            app = candidate;
            break;
        }
    }
    if (app == nil) {
        for (TemporaryApp* candidate in host.appList) {
            if ([candidate.name caseInsensitiveCompare:appParam] == NSOrderedSame) {
                app = candidate;
                break;
            }
        }
    }

    if (app == nil) {
        [self clearPendingLaunch];
        [self showPendingLaunchError:[NSString stringWithFormat:@"\"%@\" was not found on %@. Open the PC in Starlight once to refresh its app list.", appParam, host.name]];
        return;
    }

    // Cover the main screen with a start screen for this app
    [self showLaunchOverlayForApp:app];
    if (_pendingLaunchWaking && host.state != StateOnline) {
        _launchStatusLabel.text = [NSString stringWithFormat:@"Waking %@...", host.name];
    }
    
    if (host.state != StateOnline && !force) {
        // Give discovery a moment to find the PC and refresh its address and running game.
        // Discovery doesn't notify us when a known host comes online, so poll its state.
        if (!_pendingLaunchFallbackScheduled) {
            _pendingLaunchFallbackScheduled = YES;
            if ([self autoWakeEnabled] && [self canWakeHost:host]) {
                // Asleep or off: wake it and wait up to ~60 s (re-sending the request every 10 s)
                Log(LOG_I, @"Waking %@ before launching %@", host.name, app.name);
                _pendingLaunchWaking = YES;
                _launchStatusLabel.text = [NSString stringWithFormat:@"Waking %@...", host.name];
                [self sendWakeToHost:host];
                [self pollPendingLaunchHost:host remainingChecks:120];
            }
            else {
                Log(LOG_I, @"Waiting for %@ to come online before launching %@", host.name, app.name);
                [self pollPendingLaunchHost:host remainingChecks:6];
            }
        }
        return;
    }

    Log(LOG_I, @"Launching %@ on %@ from deep link", app.name, host.name);
    [self clearPendingLaunch];

    TemporaryApp* runningApp = [self findRunningApp:host];
    if (runningApp == nil || [runningApp.id isEqualToString:app.id]) {
        // Start (or resume) straight away, keeping the start screen up until the stream view appears
        [_appManager stopRetrieving];
        [self prepareToStreamApp:app];
        [self performSegueWithIdentifier:@"createStreamFrame" sender:nil];
    }
    else {
        // A different app is running on the PC: show the usual resume/quit menu
        [self hideLaunchOverlay];
        [self appClicked:app view:self.view];
    }
}

#pragma mark - Launch start screen

// Full-screen start screen shown while a deep link / pinned game launches,
// so the main screen is never visible. app may be nil before the host list is checked.
- (void)showLaunchOverlayForApp:(TemporaryApp*)app {
    UIView* container = self.navigationController.view ?: self.view;
    if (container == nil) {
        return;
    }
    
    if (_launchOverlay == nil) {
        _launchOverlay = [[UIView alloc] initWithFrame:container.bounds];
        _launchOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _launchOverlay.backgroundColor = [UIColor blackColor];
        [container addSubview:_launchOverlay];
    }
    else {
        [container bringSubviewToFront:_launchOverlay];
    }
    
    // Rebuild the contents (cheap) so a later call with the resolved app fills in art and names
    for (UIView* subview in [_launchOverlay.subviews copy]) {
        [subview removeFromSuperview];
    }
    
#if !TARGET_OS_TV
    // Same look as the stream screen's loading state (StreamFrameViewController), so the
    // hand-off to it is seamless: game background, dimmed, with the system spinner and status text
    UIImage* background = nil;
    if (app != nil) {
        SteamGridDBManager* sgdb = [SteamGridDBManager sharedManager];
        NSString* path = [sgdb cachedPathForAppName:app.name kind:SteamGridDBKindHero] ?: [sgdb cachedPathForAppName:app.name kind:SteamGridDBKindGrid];
        background = path != nil ? [UIImage imageWithContentsOfFile:path] : nil;
    }
    if (background != nil) {
        UIImageView* backgroundView = [[UIImageView alloc] initWithFrame:_launchOverlay.bounds];
        backgroundView.image = background;
        backgroundView.contentMode = UIViewContentModeScaleAspectFill;
        backgroundView.clipsToBounds = YES;
        backgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_launchOverlay addSubview:backgroundView];
        
        UIView* dim = [[UIView alloc] initWithFrame:_launchOverlay.bounds];
        dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_launchOverlay addSubview:dim];
    }
#endif
    
    UILabel* status = [[UILabel alloc] init];
    status.text = app != nil ? [NSString stringWithFormat:@"Starting %@...", app.name] : @"Starting...";
    _launchStatusLabel = status;
    status.textColor = [UIColor whiteColor];
    status.textAlignment = NSTextAlignmentCenter;
    status.translatesAutoresizingMaskIntoConstraints = NO;
    [_launchOverlay addSubview:status];
    
    UIActivityIndicatorView* spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.color = [UIColor whiteColor];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];
    [_launchOverlay addSubview:spinner];
    
    UILabel* tip = [[UILabel alloc] init];
    tip.text = @"Tip: Swipe from the left edge or hold Start + Select for the stream menu";
    tip.textColor = [UIColor whiteColor];
    tip.textAlignment = NSTextAlignmentCenter;
    tip.translatesAutoresizingMaskIntoConstraints = NO;
    [_launchOverlay addSubview:tip];
    
    [NSLayoutConstraint activateConstraints:@[
        [status.centerXAnchor constraintEqualToAnchor:_launchOverlay.centerXAnchor],
        [status.centerYAnchor constraintEqualToAnchor:_launchOverlay.centerYAnchor],
        [spinner.centerXAnchor constraintEqualToAnchor:_launchOverlay.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:status.topAnchor constant:-20],
        [tip.centerXAnchor constraintEqualToAnchor:_launchOverlay.centerXAnchor],
        [NSLayoutConstraint constraintWithItem:tip attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual
                                        toItem:_launchOverlay attribute:NSLayoutAttributeCenterY multiplier:1.8 constant:0],
    ]];
}

- (void)hideLaunchOverlay {
    [_launchOverlay removeFromSuperview];
    _launchOverlay = nil;
}

#pragma mark - Pinned games (app icon quick actions)

static NSString* const kPinnedAppsKey = @"StarlightPinnedApps";
static const NSUInteger kMaxQuickActions = 4;

- (NSArray<NSDictionary*>*)pinnedApps {
    NSArray* pinned = [[NSUserDefaults standardUserDefaults] arrayForKey:kPinnedAppsKey];
    return pinned ?: @[];
}

- (BOOL)isAppPinned:(TemporaryApp*)app {
    for (NSDictionary* entry in [self pinnedApps]) {
        if ([entry[@"host"] isEqualToString:app.host.uuid] && [entry[@"app"] isEqualToString:app.id]) {
            return YES;
        }
    }
    return NO;
}

- (void)togglePinForApp:(TemporaryApp*)app {
    NSMutableArray* pinned = [[self pinnedApps] mutableCopy];
    for (NSDictionary* entry in [pinned copy]) {
        if ([entry[@"host"] isEqualToString:app.host.uuid] && [entry[@"app"] isEqualToString:app.id]) {
            [pinned removeObject:entry];
            [[NSUserDefaults standardUserDefaults] setObject:pinned forKey:kPinnedAppsKey];
            [self updateHostShortcuts];
            return;
        }
    }
    
    if (pinned.count >= kMaxQuickActions) {
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Pin Limit Reached"
                                                                       message:[NSString stringWithFormat:@"iOS shows up to %lu items in the app icon menu. Unpin a game first.", (unsigned long)kMaxQuickActions]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [[self activeViewController] presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    [pinned addObject:@{ @"host": app.host.uuid,
                         @"app": app.id,
                         @"appName": app.name ?: @"",
                         @"hostName": app.host.name ?: @"" }];
    [[NSUserDefaults standardUserDefaults] setObject:pinned forKey:kPinnedAppsKey];
    [self updateHostShortcuts];
    
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Pinned to App Icon"
                                                                   message:[NSString stringWithFormat:@"Long-press the Starlight icon on the Home Screen and tap \"%@\" to start streaming it directly.", app.name]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self activeViewController] presentViewController:alert animated:YES completion:nil];
}

// Checks every 0.5s (up to remainingChecks times, ~3s) whether the host is online,
// then launches; after the last check it launches anyway with the last known address.
- (void)pollPendingLaunchHost:(TemporaryHost*)host remainingChecks:(int)remainingChecks {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_pendingLaunchFallbackScheduled) {
            // Launched or cancelled in the meantime
            return;
        }
        if (host.state == StateOnline || remainingChecks <= 1) {
            if (self->_pendingLaunchWaking && host.state == StateOnline) {
                self->_launchStatusLabel.text = [NSString stringWithFormat:@"%@ is awake", host.name];
            }
            [self handlePendingLaunch:YES];
        }
        else {
            // Every 10 s while waking, send the request again (the first packet can be lost while the NIC sleeps)
            if (self->_pendingLaunchWaking && remainingChecks % 20 == 0) {
                [self sendWakeToHost:host];
            }
            [self pollPendingLaunchHost:host remainingChecks:remainingChecks - 1];
        }
    });
}

- (void)handlePendingLaunchNotification {
    if (!_background && self.view.window != nil) {
        [self showLaunchOverlayForApp:nil];
    }
    [self handlePendingLaunch:NO];
}

-(void)handleReturnToForeground
{
    _background = NO;
    
    [self beginForegroundRefresh];
    
    // Check for a pending shortcut action when returning to foreground
    [self handlePendingShortcutAction];

    // Check for a pending deep link launch
    [self handlePendingLaunch:NO];
}

-(void)handleEnterBackground
{
    _background = YES;
    
    [_discMan stopDiscovery];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
#if !TARGET_OS_TV
    [[self revealViewController] setPrimaryViewController:self];
#endif
    
#if !TARGET_OS_TV
    [self.navigationController setNavigationBarHidden:(_home != nil) animated:NO];
#else
    [self.navigationController setNavigationBarHidden:NO animated:YES];
#endif
    
    // Hide 1px border line
    UIImage* fakeImage = [[UIImage alloc] init];
    [self.navigationController.navigationBar setShadowImage:fakeImage];
    [self.navigationController.navigationBar setBackgroundImage:fakeImage forBarPosition:UIBarPositionAny barMetrics:UIBarMetricsDefault];
    
    // Check for a pending shortcut action when appearing
    [self handlePendingShortcutAction];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleReturnToForeground)
                                                 name: UIApplicationDidBecomeActiveNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleEnterBackground)
                                                 name: UIApplicationWillResignActiveNotification
                                               object: nil];

    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handlePendingLaunchNotification)
                                                 name: @"StarlightPendingLaunch"
                                               object: nil];

#if !TARGET_OS_TV
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleArtworkUpdated:)
                                                 name: SteamGridDBArtworkUpdatedNotification
                                               object: nil];
#endif
    
#if !TARGET_OS_TV
    // Keep the home screen's PC/game state fresh (online status, running game)
    [_homeRefreshTimer invalidate];
    if (_home != nil) {
        // Controller navigation on the Starlight screens (the stream takes over the controller while it runs)
        [_home setControllerInputActive:YES];
        [self pushHomeState];
        _homeRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(pushHomeState) userInfo:nil repeats:YES];
    }
#endif
    
    // Check for a pending deep link launch (cold start or returning from a stream)
    [self handlePendingLaunch:NO];
    
#if !TARGET_OS_TV
    // "Quit Game" from the stream menu
    [self handlePendingQuitAfterStream];
#endif
}

#if !TARGET_OS_TV
- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    // The stream screen and system transitions can restore the navigation bar; Starlight never shows it
    if (_home != nil && !self.navigationController.navigationBarHidden && self.navigationController.topViewController == self) {
        [self.navigationController setNavigationBarHidden:YES animated:NO];
    }
}
#endif

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    // We can get here on home press while streaming
    // since the stream view segues to us just before
    // entering the background. We can't check the app
    // state here (since it's in transition), so we have
    // to use this function that will use our internal
    // state here to determine whether we're foreground.
    //
    // Note that this is neccessary here as we may enter
    // this view via an error dialog from the stream
    // view, so we won't get a return to active notification
    // for that which would normally fire beginForegroundRefresh.
    [self beginForegroundRefresh];
    
#if !TARGET_OS_TV
    [self.navigationController setNavigationBarHidden:(_home != nil) animated:NO];
#endif
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    
    // The stream view is up (or we left for another reason): drop the start screen
    [self hideLaunchOverlay];
    
#if !TARGET_OS_TV
    [_homeRefreshTimer invalidate];
    _homeRefreshTimer = nil;
    [_home setControllerInputActive:NO];
#endif
    
    // when discovery stops, we must create a new instance because
    // you cannot restart an NSOperation when it is finished
    [_discMan stopDiscovery];
    
    // Purge the box art cache
    [_boxArtCache removeAllObjects];
    
    // Remove our lifetime observers to avoid triggering them
    // while streaming
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void) retrieveSavedHosts {
    DataManager* dataMan = [[DataManager alloc] init];
    NSArray* hosts = [dataMan getHosts];
    @synchronized(hostList) {
        [hostList addObjectsFromArray:hosts];
        
        // Initialize the non-persistent host state
        for (TemporaryHost* host in hostList) {
            if (host.activeAddress == nil) {
                host.activeAddress = host.localAddress;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.externalAddress;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.address;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.ipv6Address;
            }
        }
    }
}

- (void) updateAllHosts:(NSArray *)hosts {
    // We must copy the array here because it could be modified
    // before our main thread dispatch happens.
    NSArray* hostsCopy = [NSArray arrayWithArray:hosts];
    dispatch_async(dispatch_get_main_queue(), ^{
        Log(LOG_D, @"New host list:");
        for (TemporaryHost* host in hostsCopy) {
            Log(LOG_D, @"Host: \n{\n\t name:%@ \n\t address:%@ \n\t localAddress:%@ \n\t externalAddress:%@ \n\t ipv6Address:%@ \n\t uuid:%@ \n\t mac:%@ \n\t pairState:%d \n\t online:%d \n\t activeAddress:%@ \n}", host.name, host.address, host.localAddress, host.externalAddress, host.ipv6Address, host.uuid, host.mac, host.pairState, host.state, host.activeAddress);
        }
        @synchronized(hostList) {
            [hostList removeAllObjects];
            [hostList addObjectsFromArray:hostsCopy];
        }
        [self updateHosts];

        // Discovery may have just found the PC a deep link is waiting for
        [self handlePendingLaunch:NO];
    });
}

- (void)updateHostShortcuts {
#if !TARGET_OS_TV
    NSMutableArray* quickActions = [[NSMutableArray alloc] init];
    
    // Pinned games come first and launch straight into a stream
    for (NSDictionary* entry in [self pinnedApps]) {
        if (quickActions.count >= kMaxQuickActions) {
            break;
        }
        UIApplicationShortcutItem* shortcut = [[UIApplicationShortcutItem alloc]
                                               initWithType:@"App"
                                               localizedTitle:entry[@"appName"]
                                               localizedSubtitle:entry[@"hostName"]
                                               icon:[UIApplicationShortcutIcon iconWithType:UIApplicationShortcutIconTypePlay]
                                               userInfo:@{ @"host": entry[@"host"], @"app": entry[@"app"] }];
        [quickActions addObject:shortcut];
    }
    
    @synchronized (hostList) {
        for (TemporaryHost* host in hostList) {
            if (quickActions.count >= kMaxQuickActions) {
                break;
            }
            // Pair state may be unknown if we haven't polled it yet, but the app list
            // count will persist from paired PCs
            if ([host.appList count] > 0) {
                UIApplicationShortcutItem* shortcut = [[UIApplicationShortcutItem alloc]
                                                       initWithType:@"PC"
                                                       localizedTitle:host.name
                                                       localizedSubtitle:nil
                                                       icon:[UIApplicationShortcutIcon iconWithType:UIApplicationShortcutIconTypePlay]
                                                       userInfo:[NSDictionary dictionaryWithObject:host.uuid forKey:@"UUID"]];
                [quickActions addObject: shortcut];
            }
        }
    }
    
    [UIApplication sharedApplication].shortcutItems = quickActions;
    
    [self saveGameCatalog];
#endif
}

#if !TARGET_OS_TV
#pragma mark - Game artwork (SteamGridDB)

- (NSString*)catalogArtPathForApp:(TemporaryApp*)app {
    SteamGridDBManager* sgdb = [SteamGridDBManager sharedManager];
    NSString* path = [sgdb cachedPathForAppName:app.name kind:SteamGridDBKindIcon]
                  ?: [sgdb cachedPathForAppName:app.name kind:SteamGridDBKindGrid]
                  ?: [AppAssetManager boxArtPathForApp:app];
    return path ?: @"";
}

- (void)fetchArtworkForHosts:(NSArray<TemporaryHost*>*)hosts force:(BOOL)force completion:(void (^)(NSUInteger fetched, NSUInteger notFound, NSUInteger failed))completion {
    SteamGridDBManager* sgdb = [SteamGridDBManager sharedManager];
    if (![sgdb isConfigured]) {
        if (completion != nil) {
            completion(0, 0, 0);
        }
        return;
    }
    
    NSMutableArray* names = [NSMutableArray array];
    for (TemporaryHost* host in hosts) {
        for (TemporaryApp* app in host.appList) {
            if (app.name.length > 0) {
                [names addObject:app.name];
            }
        }
    }
    [sgdb fetchArtworkForAppNames:names force:force completion:completion];
}

- (void)handleArtworkUpdated:(NSNotification*)notification {
    [_boxArtCache removeAllObjects];
    [self.collectionView reloadData];
    [self saveGameCatalog];
    [self pushHomeState];
}

- (void)showArtworkSettings {
    SteamGridDBManager* sgdb = [SteamGridDBManager sharedManager];
    NSString* status = [sgdb isConfigured]
        ? [NSString stringWithFormat:@"API key set (…%@).", [sgdb.apiKey substringFromIndex:MAX(0, (NSInteger)sgdb.apiKey.length - 4)]]
        : @"No API key yet.";
    NSString* message = [NSString stringWithFormat:@"%@\n\nCovers, backgrounds, logos and icons come from SteamGridDB. Get a free API key at steamgriddb.com → Preferences → API, then paste it below.", status];
    
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Game Artwork"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* textField) {
        textField.placeholder = [sgdb isConfigured] ? @"New API key (optional)" : @"SteamGridDB API key";
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.secureTextEntry = YES;
    }];
    
    NSArray* allHosts;
    @synchronized (hostList) {
        allHosts = [hostList allObjects];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Save Key & Download" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        NSString* entered = alert.textFields.firstObject.text;
        if (entered.length > 0) {
            sgdb.apiKey = entered;
        }
        if (![sgdb isConfigured]) {
            return;
        }
        [self fetchArtworkForHosts:allHosts force:NO completion:^(NSUInteger fetched, NSUInteger notFound, NSUInteger failed) {
            [self showArtworkResultFetched:fetched notFound:notFound failed:failed];
        }];
    }]];
    
    if ([sgdb isConfigured]) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Re-download All Artwork" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            [self fetchArtworkForHosts:allHosts force:YES completion:^(NSUInteger fetched, NSUInteger notFound, NSUInteger failed) {
                [self->_boxArtCache removeAllObjects];
                [self.collectionView reloadData];
                [self saveGameCatalog];
                [self showArtworkResultFetched:fetched notFound:notFound failed:failed];
            }];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Remove Key & Artwork" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
            sgdb.apiKey = nil;
            [sgdb clearCache];
            [self->_boxArtCache removeAllObjects];
            [self.collectionView reloadData];
            [self saveGameCatalog];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [[self activeViewController] presentViewController:alert animated:YES completion:nil];
}

- (void)showArtworkResultFetched:(NSUInteger)fetched notFound:(NSUInteger)notFound failed:(NSUInteger)failed {
    NSString* message;
    if (failed > 0 && fetched == 0) {
        message = @"Couldn't reach SteamGridDB. Check the API key and your connection.";
    }
    else {
        message = [NSString stringWithFormat:@"Downloaded artwork for %lu game(s).", (unsigned long)fetched];
        if (notFound > 0) {
            message = [message stringByAppendingFormat:@" %lu not found on SteamGridDB.", (unsigned long)notFound];
        }
        if (failed > 0) {
            message = [message stringByAppendingFormat:@" %lu failed; try again later.", (unsigned long)failed];
        }
        if (fetched == 0 && notFound == 0 && failed == 0) {
            message = @"All games already have artwork.";
        }
    }
    UIAlertController* done = [UIAlertController alertControllerWithTitle:@"Game Artwork" message:message preferredStyle:UIAlertControllerStyleAlert];
    [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self activeViewController] presentViewController:done animated:YES completion:nil];
}

#pragma mark - Starlight home screen (SwiftUI)

- (void)installHomeIfNeeded {
    if (_home != nil) {
        return;
    }
    // The classic layout is gone; clear the old preference
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"StarlightClassicLayout"];
    
    _home = [[StarlightHomeController alloc] init];
    __weak MainFrameViewController* weakSelf = self;
    
    _home.onSelectHost = ^(NSString* hostUUID) {
        [weakSelf homeSelectedHost:hostUUID];
    };
    _home.onLaunchApp = ^(NSString* hostUUID, NSString* appId) {
        MainFrameViewController* strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        AppDelegate* delegate = (AppDelegate*)[UIApplication sharedApplication].delegate;
        delegate.pendingLaunchHost = hostUUID;
        delegate.pendingLaunchApp = appId;
        [strongSelf handlePendingLaunch:NO];
    };
    _home.onAppAction = ^(NSString* action, NSString* hostUUID, NSString* appId) {
        [weakSelf homeAppAction:action host:hostUUID app:appId];
    };
    _home.onCommand = ^(NSString* command) {
        [weakSelf homeCommand:command];
    };
    _home.onHostAction = ^(NSString* action, NSString* hostUUID) {
        [weakSelf homeHostAction:action host:hostUUID];
    };
    _home.onArtworkCommand = ^(NSString* command, NSString* key) {
        [weakSelf homeArtworkCommand:command key:key];
    };
    _home.settingsProvider = ^NSDictionary<NSString*, id>* {
        return [weakSelf homeStreamSettings];
    };
    _home.onSaveSettings = ^(NSDictionary<NSString*, id>* settings) {
        [weakSelf homeSaveStreamSettings:settings];
    };
    _home.artworkRequest = ^(NSString* action, NSDictionary<NSString*, id>* params, void (^reply)(NSDictionary<NSString*, id>*)) {
        [weakSelf homeArtworkRequest:action params:params reply:reply];
    };
    
    UIViewController* homeVC = _home.viewController;
    [self addChildViewController:homeVC];
    homeVC.view.frame = self.view.bounds;
    homeVC.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:homeVC.view];
    [homeVC didMoveToParentViewController:self];
    
    [self.navigationController setNavigationBarHidden:YES animated:NO];
    [self pushHomeState];
}

- (TemporaryHost*)hostWithUUID:(NSString*)uuid {
    if (uuid == nil) {
        return nil;
    }
    @synchronized (hostList) {
        for (TemporaryHost* host in hostList) {
            if ([host.uuid isEqualToString:uuid]) {
                return host;
            }
        }
    }
    return nil;
}

- (TemporaryApp*)appWithId:(NSString*)appId onHost:(TemporaryHost*)host {
    for (TemporaryApp* app in host.appList) {
        if ([app.id isEqualToString:appId]) {
            return app;
        }
    }
    return nil;
}

- (NSString*)homeCurrentHostUUID {
    NSString* uuid = _homeHostUUID ?: [[NSUserDefaults standardUserDefaults] stringForKey:@"StarlightLastHost"];
    if ([self hostWithUUID:uuid] != nil) {
        return uuid;
    }
    if (_selectedHost.uuid != nil) {
        return _selectedHost.uuid;
    }
    // Fall back to a paired PC, preferring one that's online
    TemporaryHost* best = nil;
    @synchronized (hostList) {
        for (TemporaryHost* host in hostList) {
            if (host.pairState != PairStatePaired && host.serverCert == nil) {
                continue;
            }
            if (best == nil || (host.state == StateOnline && best.state != StateOnline)) {
                best = host;
            }
        }
    }
    return best.uuid;
}

- (void)recordLastPlayedForApp:(TemporaryApp*)app {
    if (app.host.uuid == nil || app.id == nil) {
        return;
    }
    NSMutableDictionary* lastPlayed = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"StarlightLastPlayed"] mutableCopy] ?: [NSMutableDictionary dictionary];
    lastPlayed[[NSString stringWithFormat:@"%@|%@", app.host.uuid, app.id]] = @([[NSDate date] timeIntervalSince1970]);
    [[NSUserDefaults standardUserDefaults] setObject:lastPlayed forKey:@"StarlightLastPlayed"];
}

- (void)pushHomeState {
    if (_home == nil) {
        return;
    }
    
    NSString* currentUUID = [self homeCurrentHostUUID];
    NSMutableArray* hosts = [NSMutableArray array];
    NSArray* sortedHosts;
    @synchronized (hostList) {
        sortedHosts = [[hostList allObjects] sortedArrayUsingComparator:^NSComparisonResult(TemporaryHost* a, TemporaryHost* b) {
            return [a.name ?: @"" localizedCaseInsensitiveCompare:b.name ?: @""];
        }];
    }
    for (TemporaryHost* host in sortedHosts) {
        if (host.uuid == nil) {
            continue;
        }
        [hosts addObject:@{ @"uuid": host.uuid,
                            @"name": host.name ?: @"PC",
                            @"online": @(host.state == StateOnline),
                            @"paired": @(host.pairState == PairStatePaired || (host.pairState == PairStateUnknown && host.serverCert != nil)),
                            @"showHidden": @(_showHiddenApps && [host.uuid isEqualToString:currentUUID]),
                            @"permissionDenied": @([_permissionDeniedHosts containsObject:host.uuid]),
                            @"address": host.activeAddress ?: (host.localAddress ?: (host.address ?: @"")) }];
    }
    
    NSMutableArray* apps = [NSMutableArray array];
    TemporaryHost* current = [self hostWithUUID:currentUUID];
    if (current != nil) {
        SteamGridDBManager* sgdb = [SteamGridDBManager sharedManager];
        NSDictionary* lastPlayed = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"StarlightLastPlayed"];
        NSFileManager* fm = [NSFileManager defaultManager];
        NSArray* pins = [self pinnedApps];
        NSDictionary* steamIds = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"StarlightSteamAppIds"];
        for (TemporaryApp* app in current.appList) {
            if (app.id == nil || app.name == nil) {
                continue;
            }
            NSInteger pinIndex = -1;
            for (NSUInteger i = 0; i < pins.count; i++) {
                NSDictionary* entry = pins[i];
                if ([entry[@"host"] isEqualToString:current.uuid] && [entry[@"app"] isEqualToString:app.id]) {
                    pinIndex = (NSInteger)i;
                    break;
                }
            }
            NSString* grid = [sgdb cachedPathForAppName:app.name kind:SteamGridDBKindGrid];
            if (grid == nil) {
                NSString* boxArt = [AppAssetManager boxArtPathForApp:app];
                grid = [fm fileExistsAtPath:boxArt] ? boxArt : @"";
            }
            NSNumber* played = lastPlayed[[NSString stringWithFormat:@"%@|%@", current.uuid, app.id]];
            NSString* hero = [sgdb cachedPathForAppName:app.name kind:SteamGridDBKindHero] ?: @"";
            NSString* logo = [sgdb cachedPathForAppName:app.name kind:SteamGridDBKindLogo] ?: @"";
            NSString* wide = [sgdb cachedPathForAppName:app.name kind:SteamGridDBKindWide] ?: @"";
            // Changes when artwork is replaced in place, so the UI reloads the images
            double artStamp = 0;
            for (NSString* path in @[grid, hero, logo, wide]) {
                if (path.length > 0) {
                    artStamp += [[[fm attributesOfItemAtPath:path error:nil] fileModificationDate] timeIntervalSince1970];
                }
            }
            [apps addObject:@{ @"host": current.uuid,
                               @"hostName": current.name ?: @"",
                               @"app": app.id,
                               @"name": app.name,
                               @"running": @([app.id isEqualToString:current.currentGame]),
                               @"pinIndex": @(pinIndex),
                               @"hidden": @(app.hidden),
                               @"gridPath": grid,
                               @"heroPath": hero,
                               @"logoPath": logo,
                               @"widePath": wide,
                               @"artStamp": @(artStamp),
                               @"steamAppId": steamIds[[NSString stringWithFormat:@"%@|%@", current.uuid, app.id]] ?: @0,
                               @"lastPlayed": played ?: @0 }];
        }
    }
    
    SteamGridDBManager* artwork = [SteamGridDBManager sharedManager];
    NSString* key = artwork.apiKey ?: @"";
    NSDictionary* artworkState = @{ @"configured": @([artwork isConfigured]),
                                    @"keySuffix": key.length >= 4 ? [key substringFromIndex:key.length - 4] : @"" };
    
    [_home updateWithHosts:hosts selectedHost:current.uuid apps:apps artwork:artworkState];
}

- (void)homeSelectedHost:(NSString*)hostUUID {
    TemporaryHost* host = [self hostWithUUID:hostUUID];
    if (host == nil) {
        return;
    }
    _homeHostUUID = hostUUID;
    [[NSUserDefaults standardUserDefaults] setObject:hostUUID forKey:@"StarlightLastHost"];
    [self pushHomeState];
    
    if (![_selectedHost.uuid isEqualToString:hostUUID]) {
        _showHiddenApps = NO;
    }
    
    // Online: pair if needed and load its games. Offline: just show the cached games
    // (Wake PC lives in Settings › PCs)
    if (host.state == StateOnline) {
        [self hostClicked:host view:self.view];
    }
}

- (void)homeAppAction:(NSString*)action host:(NSString*)hostUUID app:(NSString*)appId {
    TemporaryHost* host = [self hostWithUUID:hostUUID];
    TemporaryApp* app = host != nil ? [self appWithId:appId onHost:host] : nil;
    if (app == nil) {
        return;
    }
    
    if ([action isEqualToString:@"pin"]) {
        [self togglePinForApp:app];
    }
    else if ([action isEqualToString:@"copyLink"]) {
        NSString* link = [self launchLinkForApp:app];
        [UIPasteboard generalPasteboard].string = link;
        UIAlertController* copied = [UIAlertController alertControllerWithTitle:@"Shortcut Link Copied"
                                                                        message:[NSString stringWithFormat:@"In the Shortcuts app, add an \"Open URLs\" action and paste this link:\n\n%@", link]
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [copied addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [[self activeViewController] presentViewController:copied animated:YES completion:nil];
    }
    else if ([action isEqualToString:@"saveIcon"]) {
        [self saveIconToPhotosForApp:app];
    }
    else if ([action isEqualToString:@"hide"]) {
        app.hidden = !app.hidden;
        [self updateAppEntry:app forHost:app.host];
        [self saveGameCatalog];
    }
    else if ([action isEqualToString:@"quit"]) {
        [self quitRunningAppOnHost:host];
    }
    [self pushHomeState];
}

- (void)homeCommand:(NSString*)command {
    TemporaryHost* host = [self hostWithUUID:[self homeCurrentHostUUID]];
    
    if ([command isEqualToString:@"addHost"]) {
        [self addHostClicked];
    }
    else if ([command isEqualToString:@"refreshHost"] && host != nil) {
        // No view: always goes through the full refresh (server info + app list)
        [self hostClicked:host view:nil];
    }
}

- (void)homeHostAction:(NSString*)action host:(NSString*)hostUUID {
    TemporaryHost* host = [self hostWithUUID:hostUUID];
    if (host == nil) {
        return;
    }
    
    if ([action isEqualToString:@"refresh"] || [action isEqualToString:@"pair"]) {
        if (![hostUUID isEqualToString:[self homeCurrentHostUUID]]) {
            _homeHostUUID = hostUUID;
            [[NSUserDefaults standardUserDefaults] setObject:hostUUID forKey:@"StarlightLastHost"];
        }
        if ([action isEqualToString:@"pair"]) {
            if (host.state != StateOnline) {
                UIAlertController* offline = [UIAlertController alertControllerWithTitle:@"PC Offline"
                                                                                 message:[NSString stringWithFormat:@"%@ needs to be on and running Sunshine or Vibepollo to pair.", host.name]
                                                                          preferredStyle:UIAlertControllerStyleAlert];
                [offline addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [[self activeViewController] presentViewController:offline animated:YES completion:nil];
            }
            else {
                // A view marks this as a user action, which is what allows pairing
                [self hostClicked:host view:self.view];
            }
        }
        else {
            // No view: goes through the full refresh (server info + app list)
            [self hostClicked:host view:nil];
        }
    }
    else if ([action isEqualToString:@"toggleHidden"]) {
        _showHiddenApps = !_showHiddenApps;
        _homeHostUUID = hostUUID;
    }
    else if ([action isEqualToString:@"wake"]) {
        [self wakeHostFromHome:host];
    }
    else if ([action isEqualToString:@"testNetwork"]) {
        [self runNetworkTestFromHome];
    }
    else if ([action isEqualToString:@"remove"]) {
        [_discMan removeHostFromDiscovery:host];
        DataManager* dataMan = [[DataManager alloc] init];
        [dataMan removeHost:host];
        @synchronized(hostList) {
            [hostList removeObject:host];
            [self updateAllHosts:[hostList allObjects]];
        }
        if ([_homeHostUUID isEqualToString:hostUUID]) {
            _homeHostUUID = nil;
        }
        if ([_selectedHost.uuid isEqualToString:hostUUID]) {
            _selectedHost = nil;
        }
        if ([[[NSUserDefaults standardUserDefaults] stringForKey:@"StarlightLastHost"] isEqualToString:hostUUID]) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"StarlightLastHost"];
        }
        [self updateHostShortcuts];
    }
    [self pushHomeState];
}

- (void)wakeHostFromHome:(TemporaryHost*)host {
    UIAlertController* wolAlert = [UIAlertController alertControllerWithTitle:@"Wake PC" message:@"" preferredStyle:UIAlertControllerStyleAlert];
    [wolAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    if (host.mac == nil || [host.mac isEqualToString:@"00:00:00:00:00:00"]) {
        wolAlert.message = @"This PC's MAC address isn't known yet, so a wake-up request can't be sent. Connect to it once while it's on.";
    } else {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [WakeOnLanManager wakeHost:host];
        });
        wolAlert.message = @"Wake-up request sent. It may take a few moments for the PC to wake. If it never does, check that Wake-on-LAN is enabled on it.";
    }
    [[self activeViewController] presentViewController:wolAlert animated:YES completion:nil];
}

- (void)runNetworkTestFromHome {
    [self showLoadingFrame:^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            unsigned int portTestResult = LiTestClientConnectivity(CONN_TEST_SERVER, 443, ML_PORT_FLAG_ALL);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideLoadingFrame:^{
                    NSString* message;
                    if (portTestResult == 0) {
                        message = @"This network doesn't appear to be blocking streaming. If you still have trouble connecting, check your PC's firewall settings.";
                    }
                    else if (portTestResult == ML_TEST_RESULT_INCONCLUSIVE) {
                        message = @"The test couldn't run because none of the connection testing servers were reachable. Check your Internet connection or try again later.";
                    }
                    else {
                        char blockedPorts[512];
                        LiStringifyPortFlags(portTestResult, "\n", blockedPorts, sizeof(blockedPorts));
                        message = [NSString stringWithFormat:@"This network seems to be blocking streaming. These ports were blocked:\n%s", blockedPorts];
                    }
                    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Network Test" message:message preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [[self activeViewController] presentViewController:alert animated:YES completion:nil];
                }];
            });
        });
    }];
}

#pragma mark - Steam foundations (Starlight)

// Vibepollo sends a fake app when this device lacks the "List applications" permission, and
// encodes the Steam appid in each Steam game's UUID: 53544541-4d00-5000-8000-<appid in hex>.
- (NSSet*)starlightFilterAppList:(NSSet*)list forHost:(TemporaryHost*)host {
    if (host.uuid == nil) {
        return list;
    }
    if (_permissionDeniedHosts == nil) {
        _permissionDeniedHosts = [NSMutableSet set];
    }
    
    NSMutableSet* filtered = [NSMutableSet set];
    BOOL denied = NO;
    NSMutableDictionary* steamIds = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"StarlightSteamAppIds"] mutableCopy] ?: [NSMutableDictionary dictionary];
    static NSString* const steamPrefix = @"53544541-4d00-5000-8000-";
    
    for (TemporaryApp* app in list) {
        if ([app.name hasPrefix:@"Permission denied"]) {
            denied = YES;
            continue;
        }
        [filtered addObject:app];
        
        NSString* key = [NSString stringWithFormat:@"%@|%@", host.uuid, app.id];
        NSString* uuid = app.uuid.lowercaseString;
        if (uuid.length == steamPrefix.length + 12 && [uuid hasPrefix:steamPrefix]) {
            unsigned long long appid = strtoull([[uuid substringFromIndex:steamPrefix.length] UTF8String], NULL, 16);
            if (appid > 0) {
                steamIds[key] = @(appid);
            }
        }
        else if (app.uuid != nil) {
            // A UUID that isn't a Steam one: not a Steam game (Desktop, emulators, custom apps)
            [steamIds removeObjectForKey:key];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:steamIds forKey:@"StarlightSteamAppIds"];
    
    if (denied) {
        [_permissionDeniedHosts addObject:host.uuid];
    }
    else {
        [_permissionDeniedHosts removeObject:host.uuid];
    }
    return filtered;
}

- (void)quitAppAfterStreamOnHostAddress:(NSString*)address {
    _pendingQuitHostAddress = address;
}

- (void)handlePendingQuitAfterStream {
    NSString* address = _pendingQuitHostAddress;
    _pendingQuitHostAddress = nil;
    if (address == nil) {
        return;
    }
    TemporaryHost* target = nil;
    @synchronized (hostList) {
        for (TemporaryHost* host in hostList) {
            if ([host.activeAddress isEqualToString:address] || [host.localAddress isEqualToString:address] ||
                [host.address isEqualToString:address] || [host.externalAddress isEqualToString:address]) {
                target = host;
                break;
            }
        }
    }
    if (target != nil) {
        [self quitRunningAppOnHost:target];
    }
}

- (void)quitRunningAppOnHost:(TemporaryHost*)host {
    // Right after a stream the running game may not be refreshed yet, so quit regardless
    TemporaryApp* runningApp = [self findRunningApp:host];
    Log(LOG_I, @"Quitting application: %@", runningApp.name ?: @"(running app)");
    [_appManager stopRetrieving];
    [self showLoadingFrame:^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            HttpManager* hMan = [[HttpManager alloc] initWithHost:host];
            HttpResponse* quitResponse = [[HttpResponse alloc] init];
            HttpRequest* quitRequest = [HttpRequest requestForResponse:quitResponse withUrlRequest:[hMan newQuitAppRequest]];
            
            // Exempt this host from discovery while handling the quit operation
            [self->_discMan pauseDiscoveryForHost:host];
            [hMan executeRequestSynchronously:quitRequest];
            if (quitResponse.statusCode == 200) {
                ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
                [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:false]
                                                                    fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
                if (![serverInfoResp isStatusOk] || [[serverInfoResp getStringTag:@"state"] hasSuffix:@"_SERVER_BUSY"]) {
                    // Newer servers report success even when another client's app didn't really quit
                    quitResponse.statusCode = 599;
                }
                else {
                    [serverInfoResp populateHost:host];
                }
            }
            [self->_discMan resumeDiscoveryForHost:host];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (quitResponse.statusCode != 200) {
                    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Couldn't Quit Game"
                                                                                   message:@"If this game was started from another device, quit it from that device."
                                                                            preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [self hideLoadingFrame:^{
                        [[self activeViewController] presentViewController:alert animated:YES completion:nil];
                    }];
                }
                else {
                    host.currentGame = @"0";
                    [self hideLoadingFrame:nil];
                }
                [self updateAppsForHost:host];
                [self pushHomeState];
            });
        });
    }];
}

- (void)homeArtworkCommand:(NSString*)command key:(NSString*)key {
    SteamGridDBManager* sgdb = [SteamGridDBManager sharedManager];
    NSArray* allHosts;
    @synchronized (hostList) {
        allHosts = [hostList allObjects];
    }
    
    if ([command isEqualToString:@"save"]) {
        NSString* trimmed = [key stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) {
            sgdb.apiKey = trimmed;
        }
        if (![sgdb isConfigured]) {
            return;
        }
        [self pushHomeState];
        [self fetchArtworkForHosts:allHosts force:NO completion:^(NSUInteger fetched, NSUInteger notFound, NSUInteger failed) {
            [self showArtworkResultFetched:fetched notFound:notFound failed:failed];
        }];
    }
    else if ([command isEqualToString:@"redownload"] && [sgdb isConfigured]) {
        [self fetchArtworkForHosts:allHosts force:YES completion:^(NSUInteger fetched, NSUInteger notFound, NSUInteger failed) {
            [self->_boxArtCache removeAllObjects];
            [self.collectionView reloadData];
            [self saveGameCatalog];
            [self showArtworkResultFetched:fetched notFound:notFound failed:failed];
        }];
    }
    else if ([command isEqualToString:@"remove"]) {
        sgdb.apiKey = nil;
        [sgdb clearCache];
        [_boxArtCache removeAllObjects];
        [self.collectionView reloadData];
        [self saveGameCatalog];
        [self pushHomeState];
    }
}

// Manual SteamGridDB choices from the Edit Artwork screen
- (void)homeArtworkRequest:(NSString*)action params:(NSDictionary<NSString*, id>*)params reply:(void (^)(NSDictionary<NSString*, id>*))reply {
    SteamGridDBManager* sgdb = [SteamGridDBManager sharedManager];
    NSString* name = [params[@"name"] isKindOfClass:[NSString class]] ? params[@"name"] : @"";
    
    if ([action isEqualToString:@"info"]) {
        NSDictionary* match = [sgdb matchForAppName:name];
        reply(@{ @"configured": @([sgdb isConfigured]),
                 @"matchId": match[@"id"] != nil ? [NSString stringWithFormat:@"%@", match[@"id"]] : @"",
                 @"matchName": match[@"name"] ?: @"" });
    }
    else if ([action isEqualToString:@"search"]) {
        [sgdb searchGames:params[@"term"] ?: @"" completion:^(NSArray<NSDictionary*>* results) {
            reply(results != nil ? @{ @"results": results } : @{ @"error": @YES });
        }];
    }
    else if ([action isEqualToString:@"options"]) {
        [sgdb artworkOptionsForAppName:name kind:params[@"kind"] ?: SteamGridDBKindGrid completion:^(NSArray<NSDictionary*>* options) {
            reply(options != nil ? @{ @"options": options } : @{ @"error": @YES });
        }];
    }
    else if ([action isEqualToString:@"setMatch"]) {
        [sgdb setMatchForAppName:name gameId:params[@"gameId"] ?: @"" gameName:params[@"gameName"] ?: @"" completion:^(BOOL ok) {
            reply(@{ @"ok": @(ok) });
        }];
    }
    else if ([action isEqualToString:@"setImage"]) {
        [sgdb setArtworkForAppName:name kind:params[@"kind"] ?: SteamGridDBKindGrid url:params[@"url"] ?: @"" completion:^(BOOL ok) {
            reply(@{ @"ok": @(ok) });
        }];
    }
    else {
        reply(@{});
    }
}

- (NSDictionary<NSString*, id>*)homeStreamSettings {
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* settings = [dataMan getSettings];
    
    // Same presets as Moonlight's settings screen, plus this device's own screen sizes
    UIWindow* window = self.view.window ?: UIApplication.sharedApplication.windows.firstObject;
    CGFloat scale = window.screen.scale > 0 ? window.screen.scale : UIScreen.mainScreen.scale;
    CGSize frame = window.frame.size;
    int fullWidth = (int)(MAX(frame.width, frame.height) * scale);
    int fullHeight = (int)(MIN(frame.width, frame.height) * scale);
    UIEdgeInsets insets = window.safeAreaInsets;
    CGFloat horizontalInsets = frame.width >= frame.height ? (insets.left + insets.right) : (insets.top + insets.bottom);
    int safeWidth = (int)((MAX(frame.width, frame.height) - horizontalInsets) * scale);
    
    NSMutableArray* resolutions = [NSMutableArray arrayWithArray:@[
        @{ @"label": @"360p", @"width": @640, @"height": @360 },
        @{ @"label": @"720p", @"width": @1280, @"height": @720 },
        @{ @"label": @"1080p", @"width": @1920, @"height": @1080 },
        @{ @"label": @"4K", @"width": @3840, @"height": @2160 },
    ]];
    if (fullWidth > 0 && fullHeight > 0) {
        if (safeWidth > 0 && safeWidth != fullWidth) {
            [resolutions addObject:@{ @"label": @"Safe Area", @"width": @(safeWidth & ~1), @"height": @(fullHeight & ~1) }];
        }
        [resolutions addObject:@{ @"label": @"Full Screen", @"width": @(fullWidth & ~1), @"height": @(fullHeight & ~1) }];
    }
    
    return @{
        @"resolutions": resolutions,
        @"width": settings.width ?: @1920,
        @"height": settings.height ?: @1080,
        @"framerate": settings.framerate ?: @60,
        @"maxFramerate": @([UIScreen mainScreen].maximumFramesPerSecond),
        @"bitrate": settings.bitrate ?: @20000,
        @"onscreenControls": settings.onscreenControls ?: @1,
        @"codec": @((int)settings.preferredCodec),
        @"absoluteTouch": @(settings.absoluteTouchMode),
        @"optimizeGames": @(settings.optimizeGames),
        @"multiController": @(settings.multiController),
        @"swapABXY": @(settings.swapABXYButtons),
        @"audioOnPC": @(settings.playAudioOnPC),
        @"hdr": @(settings.enableHdr),
        @"framePacing": @(settings.useFramePacing),
        @"btMouse": @(settings.btMouseSupport),
        @"statsOverlay": @(settings.statsOverlay),
    };
}

- (void)homeSaveStreamSettings:(NSDictionary<NSString*, id>*)values {
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* current = [dataMan getSettings];
    
    uint32_t codec = (uint32_t)[values[@"codec"] intValue];
    if (codec > CODEC_PREF_AV1) {
        codec = CODEC_PREF_AUTO;
    }
    
    [dataMan saveSettingsWithBitrate:[values[@"bitrate"] integerValue]
                           framerate:[values[@"framerate"] integerValue]
                              height:[values[@"height"] integerValue]
                               width:[values[@"width"] integerValue]
                         audioConfig:[current.audioConfig integerValue] ?: 2
                    onscreenControls:[values[@"onscreenControls"] integerValue]
                       optimizeGames:[values[@"optimizeGames"] boolValue]
                     multiController:[values[@"multiController"] boolValue]
                     swapABXYButtons:[values[@"swapABXY"] boolValue]
                           audioOnPC:[values[@"audioOnPC"] boolValue]
                      preferredCodec:codec
                      useFramePacing:[values[@"framePacing"] boolValue]
                           enableHdr:[values[@"hdr"] boolValue]
                      btMouseSupport:[values[@"btMouse"] boolValue]
                   absoluteTouchMode:[values[@"absoluteTouch"] boolValue]
                        statsOverlay:[values[@"statsOverlay"] boolValue]];
}

// Snapshot of every paired PC's games for the Shortcuts app / Siri / Spotlight
// (read by StarlightAppIntents.swift without touching Core Data)
- (void)saveGameCatalog {
    NSMutableArray* catalog = [[NSMutableArray alloc] init];
    @synchronized (hostList) {
        for (TemporaryHost* host in hostList) {
            if (host.uuid == nil) {
                continue;
            }
            for (TemporaryApp* app in host.appList) {
                if (app.id == nil || app.name == nil) {
                    continue;
                }
                [catalog addObject:@{ @"host": host.uuid,
                                      @"hostName": host.name ?: @"",
                                      @"app": app.id,
                                      @"appName": app.name,
                                      @"artPath": [self catalogArtPathForApp:app] }];
            }
        }
    }
    
    NSArray* previous = [[NSUserDefaults standardUserDefaults] arrayForKey:@"StarlightGameCatalog"];
    if ([previous isEqualToArray:catalog]) {
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:catalog forKey:@"StarlightGameCatalog"];
    
    // Let Siri/Spotlight refresh the game names (Swift class, looked up at runtime)
    Class bridge = NSClassFromString(@"StarlightIntentsBridge");
    SEL selector = NSSelectorFromString(@"catalogDidChange");
    if (bridge != nil && [bridge respondsToSelector:selector]) {
        ((void (*)(id, SEL))[bridge methodForSelector:selector])(bridge, selector);
    }
}

// Square, Home Screen-friendly copy of the game's art, saved to Photos so it can be
// picked as the icon of a shortcut ("Add to Home Screen" → choose photo)
- (void)saveIconToPhotosForApp:(TemporaryApp*)app {
    // A real square icon from SteamGridDB beats cropping the cover
    NSString* iconPath = [[SteamGridDBManager sharedManager] cachedPathForAppName:app.name kind:SteamGridDBKindIcon];
    UIImage* sgdbIcon = iconPath != nil ? [UIImage imageWithContentsOfFile:iconPath] : nil;
    if (sgdbIcon != nil && sgdbIcon.size.width > 0) {
        CGFloat side = 512;
        UIGraphicsImageRendererFormat* iconFormat = [UIGraphicsImageRendererFormat preferredFormat];
        iconFormat.scale = 1;
        iconFormat.opaque = YES;
        UIGraphicsImageRenderer* iconRenderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:iconFormat];
        UIImage* icon = [iconRenderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
            // Opaque black behind transparent icons so the Home Screen doesn't show white corners
            [[UIColor blackColor] setFill];
            UIRectFill(CGRectMake(0, 0, side, side));
            [sgdbIcon drawInRect:CGRectMake(0, 0, side, side)];
        }];
        UIImageWriteToSavedPhotosAlbum(icon, self, @selector(iconImage:didFinishSavingWithError:contextInfo:), NULL);
        return;
    }
    
    UIImage* boxArt = [MainFrameViewController loadBoxArtForCaching:app];
    if (boxArt == nil) {
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"No Artwork"
                                                                       message:[NSString stringWithFormat:@"%@ has no artwork on this PC yet.", app.name]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [[self activeViewController] presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    // Center-crop to a square, biased slightly up where cover titles usually sit
    CGSize size = boxArt.size;
    CGFloat side = MIN(size.width, size.height);
    CGFloat x = (size.width - side) / 2.0;
    CGFloat y = size.height > size.width ? (size.height - side) * 0.35 : 0;
    CGFloat outputSide = 512;
    
    UIGraphicsImageRendererFormat* format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(outputSide, outputSide) format:format];
    UIImage* icon = [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        CGFloat scale = outputSide / side;
        [boxArt drawInRect:CGRectMake(-x * scale, -y * scale, size.width * scale, size.height * scale)];
    }];
    
    UIImageWriteToSavedPhotosAlbum(icon, self, @selector(iconImage:didFinishSavingWithError:contextInfo:), NULL);
}

- (void)iconImage:(UIImage*)image didFinishSavingWithError:(NSError*)error contextInfo:(void*)contextInfo {
    NSString* title = error == nil ? @"Icon Saved to Photos" : @"Couldn't Save Icon";
    NSString* message = error == nil
        ? @"In the Shortcuts app, open your shortcut → Add to Home Screen → tap the icon → Choose Photo, and pick it."
        : [NSString stringWithFormat:@"Allow Starlight to add photos in Settings → Privacy & Security → Photos.\n\n%@", error.localizedDescription];
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self activeViewController] presentViewController:alert animated:YES completion:nil];
}
#endif

- (void)updateHosts {
    Log(LOG_I, @"Updating hosts...");
    [[hostScrollView subviews] makeObjectsPerformSelector:@selector(removeFromSuperview)];
    UIComputerView* addComp = [[UIComputerView alloc] initForAddWithCallback:self];
    UIComputerView* compView;
    float prevEdge = -1;
    @synchronized (hostList) {
        // Sort the host list in alphabetical order
        NSArray* sortedHostList = [[hostList allObjects] sortedArrayUsingSelector:@selector(compareName:)];
        for (TemporaryHost* comp in sortedHostList) {
            compView = [[UIComputerView alloc] initWithComputer:comp andCallback:self];
            compView.center = CGPointMake([self getCompViewX:compView addComp:addComp prevEdge:prevEdge], hostScrollView.frame.size.height / 2);
            prevEdge = compView.frame.origin.x + compView.frame.size.width;
            [hostScrollView addSubview:compView];
            
            // Start jobs to decode the box art in advance
            for (TemporaryApp* app in comp.appList) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                    [self updateBoxArtCacheForApp:app];
                });
            }
        }
    }
    
    // Create or delete host shortcuts as needed
    [self updateHostShortcuts];
    
    // Update the title in case we now have a PC
    [self updateTitle];
    
    prevEdge = [self getCompViewX:addComp addComp:addComp prevEdge:prevEdge];
    addComp.center = CGPointMake(prevEdge, hostScrollView.frame.size.height / 2);
    
    [hostScrollView addSubview:addComp];
    [hostScrollView setContentSize:CGSizeMake(prevEdge + addComp.frame.size.width, hostScrollView.frame.size.height)];
}

- (float) getCompViewX:(UIComputerView*)comp addComp:(UIComputerView*)addComp prevEdge:(float)prevEdge {
    float padding;
    
#if TARGET_OS_TV
    padding = 100;
#else
    padding = addComp.frame.size.width / 2;
#endif
    
    if (prevEdge == -1) {
        return hostScrollView.frame.origin.x + comp.frame.size.width / 2 + padding;
    } else {
        return prevEdge + comp.frame.size.width / 2 + padding;
    }
}

// This function forces immediate decoding of the UIImage, rather
// than the default lazy decoding that results in janky scrolling.
+ (UIImage*) loadBoxArtForCaching:(TemporaryApp*)app {
    UIImage* boxArt;
    
    NSData* imageData = nil;
#if !TARGET_OS_TV
    // Prefer the SteamGridDB cover when one has been downloaded
    NSString* gridPath = [[SteamGridDBManager sharedManager] cachedPathForAppName:app.name kind:SteamGridDBKindGrid];
    if (gridPath != nil) {
        imageData = [NSData dataWithContentsOfFile:gridPath];
    }
#endif
    if (imageData == nil) {
        imageData = [NSData dataWithContentsOfFile:[AppAssetManager boxArtPathForApp:app]];
    }
    if (imageData == nil) {
        // No box art on disk
        return nil;
    }
    
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
    CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil);
    
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef imageContext =  CGBitmapContextCreate(NULL, width, height, 8, width * 4, colorSpace,
                                                       kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);

    CGContextDrawImage(imageContext, CGRectMake(0, 0, width, height), cgImage);
    
    CGImageRef outputImage = CGBitmapContextCreateImage(imageContext);

    boxArt = [UIImage imageWithCGImage:outputImage];
    
    CGImageRelease(outputImage);
    CGContextRelease(imageContext);
    
    CGImageRelease(cgImage);
    CFRelease(source);
    
    return boxArt;
}

- (void) updateBoxArtCacheForApp:(TemporaryApp*)app {
    if ([_boxArtCache objectForKey:app] == nil) {
        UIImage* image = [MainFrameViewController loadBoxArtForCaching:app];
        if (image != nil) {
            // Add the image to our cache if it was present
            [_boxArtCache setObject:image forKey:app];
        }
    }
}

- (void) updateAppsForHost:(TemporaryHost*)host {
    if (host != _selectedHost) {
        Log(LOG_W, @"Mismatched host during app update");
        return;
    }
    
    _sortedAppList = [host.appList allObjects];
    _sortedAppList = [_sortedAppList sortedArrayUsingSelector:@selector(compareName:)];
    
    if (!_showHiddenApps) {
        NSMutableArray* visibleAppList = [NSMutableArray array];
        for (TemporaryApp* app in _sortedAppList) {
            if (!app.hidden) {
                [visibleAppList addObject:app];
            }
        }
        _sortedAppList = visibleAppList;
    }
    
    [hostScrollView removeFromSuperview];
    [self.collectionView reloadData];
    
#if !TARGET_OS_TV
    [self pushHomeState];
#endif
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell* cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"AppCell" forIndexPath:indexPath];
    
    TemporaryApp* app = _sortedAppList[indexPath.row];
    UIAppView* appView = [[UIAppView alloc] initWithApp:app cache:_boxArtCache andCallback:self];
    
    if (appView.bounds.size.width > 10.0) {
        CGFloat scale = cell.bounds.size.width / appView.bounds.size.width;
        [appView setCenter:CGPointMake(appView.bounds.size.width / 2 * scale, appView.bounds.size.height / 2 * scale)];
        appView.transform = CGAffineTransformMakeScale(scale, scale);
    }
    
    [cell.subviews.firstObject removeFromSuperview]; // Remove a view that was previously added
    [cell addSubview:appView];
    
    // Shadow opacity is controlled inside UIAppView based on whether the app
    // is hidden or not during the update cycle.
    UIBezierPath *shadowPath = [UIBezierPath bezierPathWithRect:cell.bounds];
    cell.layer.masksToBounds = NO;
    cell.layer.shadowColor = [UIColor blackColor].CGColor;
    cell.layer.shadowOffset = CGSizeMake(1.0f, 5.0f);
    cell.layer.shadowPath = shadowPath.CGPath;
    
#if !TARGET_OS_TV
    cell.layer.borderWidth = 1;
    cell.layer.borderColor = [[UIColor colorWithRed:0 green:0 blue:0 alpha:0.3f] CGColor];
    cell.exclusiveTouch = YES;
#endif

    return cell;
}

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 1; // App collection only
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (_selectedHost != nil && _sortedAppList != nil) {
        return _sortedAppList.count;
    }
    else {
        return 0;
    }
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    
    // Purge the box art cache on low memory
    [_boxArtCache removeAllObjects];
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [self.view endEditing:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#if !TARGET_OS_TV
- (BOOL)shouldAutorotate {
    return YES;
}
#endif

- (void) disableNavigation {
    self.navigationController.navigationBar.topItem.rightBarButtonItem.enabled = NO;
    self.navigationController.navigationBar.topItem.leftBarButtonItem.enabled = NO;
}

- (void) enableNavigation {
    self.navigationController.navigationBar.topItem.rightBarButtonItem.enabled = YES;
    self.navigationController.navigationBar.topItem.leftBarButtonItem.enabled = YES;
}

#if TARGET_OS_TV
- (BOOL)canBecomeFocused {
    return YES;
}
#endif

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    
#if !TARGET_OS_TV
    if (context.nextFocusedView != nil) {
        [context.nextFocusedView setAlpha:0.8];
    }
    [context.previouslyFocusedView setAlpha:1.0];
#endif
}

@end
