//
//  StreamFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/18/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "StreamFrameViewController.h"
#import "MainFrameViewController.h"
#import "VideoDecoderRenderer.h"
#import "StreamManager.h"
#import "ControllerSupport.h"
#import "DataManager.h"
#import "AppDelegate.h"
#if !TARGET_OS_TV
#import "SteamGridDBManager.h"
#endif

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <Limelight.h>

#if !TARGET_OS_TV
#import <AVKit/AVKit.h>
#endif

#if TARGET_OS_TV
#import <AVFoundation/AVDisplayCriteria.h>
#import <AVKit/AVDisplayManager.h>
#import <AVKit/UIWindow.h>
#endif

@interface AVDisplayCriteria()
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (id)initWithRefreshRate:(float)arg1 videoDynamicRange:(int)arg2;
@end

#if !TARGET_OS_TV
@interface StreamFrameViewController () <AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate>
@end
#endif

@implementation StreamFrameViewController {
    ControllerSupport *_controllerSupport;
    StreamManager *_streamMan;
    TemporarySettings *_settings;
    NSTimer *_inactivityTimer;
    NSTimer *_statsUpdateTimer;
    UITapGestureRecognizer *_menuTapGestureRecognizer;
    UITapGestureRecognizer *_menuDoubleTapGestureRecognizer;
    UITapGestureRecognizer *_playPauseTapGestureRecognizer;
    UITextView *_overlayView;
    UILabel *_stageLabel;
    UILabel *_tipLabel;
    UIActivityIndicatorView *_spinner;
    StreamView *_streamView;
    UIView *_loadingBackground;
#if !TARGET_OS_TV
    StarlightStreamMenu *_streamMenu;
#endif
    UIScrollView *_scrollView;
    BOOL _userIsInteracting;
    CGSize _keyboardSize;
    
#if !TARGET_OS_TV
    UIScreenEdgePanGestureRecognizer *_exitSwipeRecognizer;
    
    // Starlight: Picture in Picture (AVPictureInPictureController, iOS 15+)
    id _pipController;
    BOOL _pipStarting;
    BOOL _pipActive;
    BOOL _pipRestoring;
    BOOL _leavingStream;
    BOOL _menuOnDevice;
    
    // Starlight: second screen (stream on the TV, companion panel on the iPhone)
    UIWindow *_externalWindow;
    UIViewController *_companionVC;
    // Choice made in the stream menu for this stream: 0 = follow Settings, 1 = TV only, 2 = mirror
    NSInteger _externalOverride;
    
    // Starlight: reconnecting at another resolution when the stream changes screens
    BOOL _connectionReady;
    BOOL _reconnecting;
#endif
}

#if !TARGET_OS_TV
+ (void)applyResolutionToConfig:(StreamConfiguration*)config settings:(TemporarySettings*)settings tvScreen:(UIScreen*)tvScreen {
    config.frameRate = [settings.framerate intValue];
    // Don't stream more FPS than the display can show
    if (config.frameRate > [UIScreen mainScreen].maximumFramesPerSecond) {
        config.frameRate = (int)[UIScreen mainScreen].maximumFramesPerSecond;
    }
    config.width = [settings.width intValue];
    config.height = [settings.height intValue];
    
    if (tvScreen == nil) {
        return;
    }
    id match = [[NSUserDefaults standardUserDefaults] objectForKey:@"StarlightExternalMatchResolution"];
    if (match != nil && ![match boolValue]) {
        return;
    }
    CGSize size = tvScreen.currentMode != nil ? tvScreen.currentMode.size : tvScreen.nativeBounds.size;
    int width = (int)MAX(size.width, size.height);
    int height = (int)MIN(size.width, size.height);
    if (width <= 0 || height <= 0) {
        return;
    }
    if (width > 3840 || height > 2160) {
        // Keep the TV's shape, capped at 4K
        double scale = MIN(3840.0 / width, 2160.0 / height);
        width = (int)(width * scale);
        height = (int)(height * scale);
    }
    config.width = width & ~1;
    config.height = height & ~1;
    if (tvScreen.maximumFramesPerSecond > 0 && config.frameRate > tvScreen.maximumFramesPerSecond) {
        config.frameRate = (int)tvScreen.maximumFramesPerSecond;
    }
    Log(LOG_I, @"External display: streaming at %dx%d %d FPS", config.width, config.height, config.frameRate);
}
#endif

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
#if !TARGET_OS_TV
    [[self revealViewController] setPrimaryViewController:self];
    
    // The TV may have connected while this screen was still being pushed
    if (_externalWindow != nil) {
        [self showCompanionPanel];
    }
#endif
}

#if TARGET_OS_TV
- (void)controllerPauseButtonPressed:(id)sender { }
- (void)controllerPauseButtonDoublePressed:(id)sender {
    Log(LOG_I, @"Menu double-pressed -- backing out of stream");
    [self returnToMainFrame];
}
- (void)controllerPlayPauseButtonPressed:(id)sender {
    Log(LOG_I, @"Play/Pause button pressed -- backing out of stream");
    [self returnToMainFrame];
}
#endif


- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [self.navigationController setNavigationBarHidden:YES animated:YES];
    
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    
    _settings = [[[DataManager alloc] init] getSettings];
    
    _stageLabel = [[UILabel alloc] init];
    [_stageLabel setUserInteractionEnabled:NO];
    [_stageLabel setText:[NSString stringWithFormat:@"Starting %@...", self.streamConfig.appName]];
    [_stageLabel sizeToFit];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.textColor = [UIColor whiteColor];
    _stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2);
    
    _spinner = [[UIActivityIndicatorView alloc] init];
    [_spinner setUserInteractionEnabled:NO];
#if TARGET_OS_TV
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhiteLarge];
#else
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhite];
#endif
    [_spinner sizeToFit];
    [_spinner startAnimating];
    _spinner.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2 - _stageLabel.frame.size.height - _spinner.frame.size.height);
    
    _controllerSupport = [[ControllerSupport alloc] initWithConfig:self.streamConfig delegate:self];
    _inactivityTimer = nil;
    
    _streamView = [[StreamView alloc] initWithFrame:self.view.frame];
    [_streamView setupStreamView:_controllerSupport interactionDelegate:self config:self.streamConfig];
    
#if TARGET_OS_TV
    if (!_menuTapGestureRecognizer || !_menuDoubleTapGestureRecognizer || !_playPauseTapGestureRecognizer) {
        _menuTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonPressed:)];
        _menuTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];

        _playPauseTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPlayPauseButtonPressed:)];
        _playPauseTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypePlayPause)];
        
        _menuDoubleTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonDoublePressed:)];
        _menuDoubleTapGestureRecognizer.numberOfTapsRequired = 2;
        [_menuTapGestureRecognizer requireGestureRecognizerToFail:_menuDoubleTapGestureRecognizer];
        _menuDoubleTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];
    }
    
    [self.view addGestureRecognizer:_menuTapGestureRecognizer];
    [self.view addGestureRecognizer:_menuDoubleTapGestureRecognizer];
    [self.view addGestureRecognizer:_playPauseTapGestureRecognizer];

#else
    _exitSwipeRecognizer = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(edgeSwiped)];
    _exitSwipeRecognizer.edges = UIRectEdgeLeft;
    _exitSwipeRecognizer.delaysTouchesBegan = NO;
    _exitSwipeRecognizer.delaysTouchesEnded = NO;
    
    [self.view addGestureRecognizer:_exitSwipeRecognizer];
#endif
    
    _tipLabel = [[UILabel alloc] init];
    [_tipLabel setUserInteractionEnabled:NO];
    
#if TARGET_OS_TV
    [_tipLabel setText:@"Tip: Tap the Play/Pause button on the Apple TV Remote to disconnect from your PC"];
#else
    [_tipLabel setText:@"Tip: Swipe from the left edge or hold Start for the stream menu"];
#endif
    
    [_tipLabel sizeToFit];
    _tipLabel.textColor = [UIColor whiteColor];
    _tipLabel.textAlignment = NSTextAlignmentCenter;
    _tipLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height * 0.9);
    
    _streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                            renderView:_streamView
                                   connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:_streamMan];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidBecomeActive:)
                                                 name: UIApplicationDidBecomeActiveNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidEnterBackground:)
                                                 name: UIApplicationDidEnterBackgroundNotification
                                               object: nil];
    
#if !TARGET_OS_TV
    // A TV connecting or disconnecting (StarlightSceneDelegate)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(externalScreensChanged:)
                                                 name:StarlightExternalDisplayDidChangeNotification
                                               object:nil];
#endif

#if 0
    // FIXME: This doesn't work reliably on iPad for some reason. Showing and hiding the keyboard
    // several times in a row will not correctly restore the state of the UIScrollView.
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillShow:)
                                                 name: UIKeyboardWillShowNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillHide:)
                                                 name: UIKeyboardWillHideNotification
                                               object: nil];
#endif
    
    // Only enable scroll and zoom in absolute touch mode
    if (_settings.absoluteTouchMode) {
        _scrollView = [[UIScrollView alloc] initWithFrame:self.view.frame];
#if !TARGET_OS_TV
        [_scrollView.panGestureRecognizer setMinimumNumberOfTouches:2];
#endif
        [_scrollView setShowsHorizontalScrollIndicator:NO];
        [_scrollView setShowsVerticalScrollIndicator:NO];
        [_scrollView setDelegate:self];
        [_scrollView setMaximumZoomScale:10.0f];
        
        // Add StreamView inside a UIScrollView for absolute mode
        [_scrollView addSubview:_streamView];
        [self.view addSubview:_scrollView];
    }
    else {
        // Add StreamView directly in relative mode
        [self.view addSubview:_streamView];
    }
    
#if !TARGET_OS_TV
    // Starlight: show the game's art behind the loading status (same look as the launch screen)
    _loadingBackground = [self makeLoadingBackgroundWithFrame:self.view.bounds];
    [self.view addSubview:_loadingBackground];
    
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.color = [UIColor whiteColor];
#endif
    
    [self.view addSubview:_stageLabel];
    [self.view addSubview:_spinner];
    [self.view addSubview:_tipLabel];
    
#if !TARGET_OS_TV
    // A TV may already be connected when the stream starts
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateExternalDisplay];
    });
#endif
}

#if !TARGET_OS_TV
// The game's art, dimmed, behind the connection progress
- (UIView*)makeLoadingBackgroundWithFrame:(CGRect)frame {
    SteamGridDBManager* sgdb = [SteamGridDBManager sharedManager];
    NSString* backgroundPath = [sgdb cachedPathForAppName:self.streamConfig.appName kind:SteamGridDBKindHero]
        ?: [sgdb cachedPathForAppName:self.streamConfig.appName kind:SteamGridDBKindGrid];
    UIImage* background = backgroundPath != nil ? [UIImage imageWithContentsOfFile:backgroundPath] : nil;
    UIView* view = [[UIView alloc] initWithFrame:frame];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.userInteractionEnabled = NO;
    view.backgroundColor = [UIColor blackColor];
    if (background != nil) {
        UIImageView* backgroundView = [[UIImageView alloc] initWithFrame:view.bounds];
        backgroundView.image = background;
        backgroundView.contentMode = UIViewContentModeScaleAspectFill;
        backgroundView.clipsToBounds = YES;
        backgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [view addSubview:backgroundView];
        
        UIView* dim = [[UIView alloc] initWithFrame:view.bounds];
        dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [view addSubview:dim];
    }
    return view;
}

#pragma mark - Handoff (Starlight)

// While streaming: the PC and game, for the user's other iPhone or iPad. Picking it up there stops
// streaming here (the game keeps running on the PC) and resumes it there.
- (void)advertiseHandoff {
    if (self.streamConfig.hostUUID == nil || self.streamConfig.appID == nil) {
        return;
    }
    StarlightHandoff* handoff = [StarlightHandoff shared];
    [handoff advertiseStreamWithHostUUID:self.streamConfig.hostUUID
                                hostName:self.streamConfig.hostName ?: @""
                                   appID:self.streamConfig.appID
                                 appUUID:self.streamConfig.appUUID
                                 appName:self.streamConfig.appName ?: @""];
    __weak StreamFrameViewController* weakSelf = self;
    handoff.onStreamContinued = ^{
        StreamFrameViewController* strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_leavingStream) {
            return;
        }
        Log(LOG_I, @"Handoff: the stream was continued on another device, stopping it here");
        [strongSelf streamMenuAction:@"disconnect"];
    };
}

// A stream continued from another device: that device may still be letting go of the PC, so a failed
// Resume is retried for a few seconds before the error shows. YES when a retry is on its way.
- (BOOL)retryHandoffResume {
    NSDate* until = self.streamConfig.handoffRetryUntil;
    if (until == nil || [until timeIntervalSinceNow] <= 0 || _leavingStream) {
        self.streamConfig.handoffRetryUntil = nil;
        return NO;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        Log(LOG_I, @"Handoff: the PC is still busy with the other device, retrying");
        self->_stageLabel.text = @"Waiting for your other device to let go of the stream...";
        [self->_stageLabel sizeToFit];
        UIView* parent = self->_stageLabel.superview ?: self.view;
        self->_stageLabel.center = CGPointMake(parent.bounds.size.width / 2, self->_stageLabel.center.y);
        self->_streamMan = nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_leavingStream) {
                return;
            }
            self->_streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                                          renderView:self->_streamView
                                                 connectionCallbacks:self];
            NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
            [opQueue addOperation:self->_streamMan];
        });
    });
    return YES;
}

#pragma mark - Reconnecting at another resolution (Starlight)

// When the stream changes screens (stream menu, TV plugged in or out): if the resolution or frame rate it
// would start with now differs, reconnect the stream (the game keeps running on the PC)
- (void)checkStreamResolution {
    if (!_connectionReady || _reconnecting || _leavingStream || _pipActive) {
        return;
    }
    StreamConfiguration* wanted = [[StreamConfiguration alloc] init];
    UIScreen* tvScreen = _externalWindow != nil ? _externalWindow.windowScene.screen : nil;
    [StreamFrameViewController applyResolutionToConfig:wanted settings:_settings tvScreen:tvScreen];
    if (wanted.width == self.streamConfig.width && wanted.height == self.streamConfig.height
        && wanted.frameRate == self.streamConfig.frameRate) {
        return;
    }
    // Only the resolution and frame rate change
    StreamConfiguration* target = [self copyOfStreamConfig];
    target.width = wanted.width;
    target.height = wanted.height;
    target.frameRate = wanted.frameRate;
    [self reconnectWithConfig:target];
}

// The fields a reconnection can change
- (StreamConfiguration*)copyOfStreamConfig {
    StreamConfiguration* copy = [[StreamConfiguration alloc] init];
    copy.width = self.streamConfig.width;
    copy.height = self.streamConfig.height;
    copy.frameRate = self.streamConfig.frameRate;
    copy.bitRate = self.streamConfig.bitRate;
    copy.useFramePacing = self.streamConfig.useFramePacing;
    copy.supportedVideoFormats = self.streamConfig.supportedVideoFormats;
    copy.multiController = self.streamConfig.multiController;
    copy.gamepadMask = self.streamConfig.gamepadMask;
    return copy;
}

// Everything from Stream Settings as if the stream started now (resolution by the TV rule)
- (StreamConfiguration*)streamConfigFromSettings {
    StreamConfiguration* target = [self copyOfStreamConfig];
    UIScreen* tvScreen = _externalWindow != nil ? _externalWindow.windowScene.screen : nil;
    [StreamFrameViewController applyResolutionToConfig:target settings:_settings tvScreen:tvScreen];
    [MainFrameViewController applyVideoSettings:_settings toConfig:target];
    target.multiController = _settings.multiController;
    target.gamepadMask = [ControllerSupport getConnectedGamepadMask:target];
    return target;
}

// Stream Settings changed from the stream menu: Controls apply now; Video ones reconnect when asked
- (void)streamMenuSettingsChanged:(NSDictionary<NSString*, id>*)values reconnect:(BOOL)reconnect {
    [MainFrameViewController saveStreamSettingsDictionary:values];
    _settings = [[[DataManager alloc] init] getSettings];
    
    self.streamConfig.swapABXYButtons = _settings.swapABXYButtons;
    [_controllerSupport setSwapABXYButtons:_settings.swapABXYButtons];
    [_streamView applyOnScreenControlsLevel:(OnScreenControlsLevel)[_settings.onscreenControls integerValue]
                              absoluteTouch:_settings.absoluteTouchMode];
    
    if (reconnect) {
        if (!_connectionReady || _reconnecting) {
            return;
        }
        [self reconnectWithConfig:[self streamConfigFromSettings]];
    }
}

- (void)reconnectWithConfig:(StreamConfiguration*)target {
    int width = target.width;
    int height = target.height;
    Log(LOG_I, @"Reconnecting the stream at %dx%d %d FPS, %d kbps (was %dx%d %d FPS, %d kbps)", width, height,
        target.frameRate, target.bitRate, self.streamConfig.width, self.streamConfig.height,
        self.streamConfig.frameRate, self.streamConfig.bitRate);
    _reconnecting = YES;
    _connectionReady = NO;
    [self hideStreamMenu];
    [self tearDownPictureInPicture];
    if (_statsUpdateTimer != nil) {
        [_statsUpdateTimer invalidate];
        _statsUpdateTimer = nil;
    }
    [self updateOverlayText:nil];
    [self showReconnectOverlayForWidth:width height:height];
    
    StreamManager* oldStream = _streamMan;
    _streamMan = nil;
    [oldStream stopStreamWithCompletion:^{
        // A moment for the PC to close the old session before resuming
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_leavingStream) {
                return;
            }
            // The old video layer goes; the new connection brings its own
            for (CALayer* layer in [self->_streamView.layer.sublayers copy]) {
                if ([layer isKindOfClass:[AVSampleBufferDisplayLayer class]]) {
                    [layer removeFromSuperlayer];
                }
            }
            self.streamConfig.width = width;
            self.streamConfig.height = height;
            self.streamConfig.frameRate = target.frameRate;
            self.streamConfig.bitRate = target.bitRate;
            self.streamConfig.useFramePacing = target.useFramePacing;
            self.streamConfig.supportedVideoFormats = target.supportedVideoFormats;
            self.streamConfig.multiController = target.multiController;
            self.streamConfig.gamepadMask = target.gamepadMask;
            [self->_controllerSupport setMultiController:target.multiController];
            [self->_streamView updateStreamAspectRatio:(float)width / (float)height];
            
            // From here, a failure is the new connection's: shown as usual
            self->_reconnecting = NO;
            UIApplication.sharedApplication.idleTimerDisabled = YES;
            self->_streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                                          renderView:self->_streamView
                                                 connectionCallbacks:self];
            NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
            [opQueue addOperation:self->_streamMan];
        });
    }];
}

// The game's art and the connection progress, where the stream will show (the TV, or the device)
- (void)showReconnectOverlayForWidth:(int)width height:(int)height {
    UIView* parent = _externalWindow != nil ? _externalWindow.rootViewController.view : self.view;
    UIView* overlay = [self makeLoadingBackgroundWithFrame:parent.bounds];
    
    UIActivityIndicatorView* spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.color = [UIColor whiteColor];
    [spinner startAnimating];
    UILabel* label = [[UILabel alloc] init];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.text = [NSString stringWithFormat:@"Reconnecting %@ at %dx%d...", self.streamConfig.appName ?: @"", width, height];
    [label sizeToFit];
    CGPoint middle = CGPointMake(CGRectGetMidX(overlay.bounds), CGRectGetMidY(overlay.bounds));
    label.center = middle;
    spinner.center = CGPointMake(middle.x, middle.y - label.frame.size.height - spinner.frame.size.height);
    UIViewAutoresizing centred = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
        | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    label.autoresizingMask = centred;
    spinner.autoresizingMask = centred;
    [overlay addSubview:spinner];
    [overlay addSubview:label];
    
    overlay.alpha = 0;
    [parent addSubview:overlay];
    [UIView animateWithDuration:0.25 animations:^{
        overlay.alpha = 1;
    }];
    
    // The connection callbacks update and remove these, as on the first connection
    [_loadingBackground removeFromSuperview];
    _loadingBackground = overlay;
    [_stageLabel removeFromSuperview];
    _stageLabel = label;
    [_spinner removeFromSuperview];
    _spinner = spinner;
}

// Starlight: the screen may still be turning to landscape when the stream screen loads.
// Keep the video sized to the screen (on the device; the TV has its own window).
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_externalWindow != nil || _streamView == nil) {
        return;
    }
    UIView* container = [self streamContainer];
    if (container.superview == self.view && !CGRectEqualToRect(container.frame, self.view.bounds)) {
        container.frame = self.view.bounds;
        if (_scrollView != nil && _scrollView.zoomScale == 1.0) {
            _streamView.frame = _scrollView.bounds;
        }
        [self layoutDisplayLayer];
    }
}
#endif

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _streamView;
}

- (void)willMoveToParentViewController:(UIViewController *)parent {
    // Only cleanup when we're being destroyed
    if (parent == nil) {
#if !TARGET_OS_TV
        [self tearDownPictureInPicture];
        [self tearDownExternalDisplay];
#endif
        [_controllerSupport cleanup];
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        [_streamMan stopStream];
        if (_inactivityTimer != nil) {
            [_inactivityTimer invalidate];
            _inactivityTimer = nil;
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

#if 0
- (void)keyboardWillShow:(NSNotification *)notification {
    _keyboardSize = [[[notification userInfo] objectForKey:UIKeyboardFrameBeginUserInfoKey] CGRectValue].size;

    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height -= self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}

-(void)keyboardWillHide:(NSNotification *)notification {
    // NOTE: UIKeyboardFrameEndUserInfoKey returns a different keyboard size
    // than UIKeyboardFrameBeginUserInfoKey, so it's unsuitable for use here
    // to undo the changes made by keyboardWillShow.
    
    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height += self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}
#endif

- (void)updateStatsOverlay {
    NSString* overlayText = [self->_streamMan getStatsOverlayText];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateOverlayText:overlayText];
    });
}

- (void)updateOverlayText:(NSString*)text {
    if (_overlayView == nil) {
        _overlayView = [[UITextView alloc] init];
#if !TARGET_OS_TV
        [_overlayView setEditable:NO];
#endif
        [_overlayView setUserInteractionEnabled:NO];
        [_overlayView setSelectable:NO];
        [_overlayView setScrollEnabled:NO];
        
        // HACK: If not using stats overlay, center the text
        if (_statsUpdateTimer == nil) {
            [_overlayView setTextAlignment:NSTextAlignmentCenter];
        }
        
        [_overlayView setTextColor:[UIColor lightGrayColor]];
        [_overlayView setBackgroundColor:[UIColor blackColor]];
#if TARGET_OS_TV
        [_overlayView setFont:[UIFont systemFontOfSize:24]];
#else
        [_overlayView setFont:[UIFont systemFontOfSize:12]];
#endif
        [_overlayView setAlpha:0.5];
    }
    
    // Starlight: the overlay goes with the stream (the TV's window in Second Screen)
    UIView* parent = self.view;
#if !TARGET_OS_TV
    if (_externalWindow != nil) {
        parent = _externalWindow.rootViewController.view;
    }
#endif
    if (_overlayView.superview != parent) {
        [_overlayView removeFromSuperview];
        [parent addSubview:_overlayView];
    }
    [parent bringSubviewToFront:_overlayView];
    
    if (text != nil) {
        // We set our bounds to the maximum width in order to work around a bug where
        // sizeToFit interacts badly with the UITextView's line breaks, causing the
        // width to get smaller and smaller each time as more line breaks are inserted.
        [_overlayView setBounds:CGRectMake(0,
                                           _overlayView.frame.origin.y,
                                           parent.bounds.size.width,
                                           _overlayView.frame.size.height)];
        [_overlayView setText:text];
        [_overlayView sizeToFit];
        [_overlayView setCenter:CGPointMake(parent.bounds.size.width / 2, _overlayView.frame.size.height / 2)];
        [_overlayView setHidden:NO];
    }
    else {
        [_overlayView setHidden:YES];
    }
}

- (void) returnToMainFrame {
#if !TARGET_OS_TV
    _leavingStream = YES;
    [[StarlightHandoff shared] endStream];
    [self tearDownPictureInPicture];
    [self tearDownExternalDisplay];
#endif
    
    // Reset display mode back to default
    [self updatePreferredDisplayMode:NO];
    
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    
    [self.navigationController popToRootViewControllerAnimated:YES];
}

// This will fire if the user opens control center or gets a low battery message
- (void)applicationWillResignActive:(NSNotification *)notification {
    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
    }
    
#if !TARGET_OS_TV
    // Terminate the stream if the app is inactive for 60 seconds
    Log(LOG_I, @"Starting inactivity termination timer");
    _inactivityTimer = [NSTimer scheduledTimerWithTimeInterval:60
                                                      target:self
                                                    selector:@selector(inactiveTimerExpired:)
                                                    userInfo:nil
                                                     repeats:NO];
#endif
}

- (void)inactiveTimerExpired:(NSTimer*)timer {
#if !TARGET_OS_TV
    if ([self pipKeepsStreamAlive]) {
        Log(LOG_I, @"Inactivity timer expired, but the stream is in Picture in Picture");
        _inactivityTimer = nil;
        return;
    }
#endif
    Log(LOG_I, @"Terminating stream after inactivity");

    [self returnToMainFrame];
    
    _inactivityTimer = nil;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    // Stop the background timer, since we're foregrounded again
    if (_inactivityTimer != nil) {
        Log(LOG_I, @"Stopping inactivity timer after becoming active again");
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }

#if !TARGET_OS_TV
    // Opening Starlight again (from its icon) brings the stream back full screen
    if (_pipActive) {
        if (@available(iOS 15.0, *)) {
            _pipRestoring = YES;
            [(AVPictureInPictureController*)_pipController stopPictureInPicture];
        }
    }
#endif
}

// This fires when the home button is pressed
- (void)applicationDidEnterBackground:(UIApplication *)application {
#if !TARGET_OS_TV
    // Starlight: Picture in Picture keeps the stream going in the background
    if ([self pipKeepsStreamAlive]) {
        Log(LOG_I, @"Entering background with the stream in Picture in Picture");
        return;
    }
    if ([self pipCanStartAutomatically]) {
        // The automatic start may still be on its way: give it a moment before tearing down
        Log(LOG_I, @"Entering background: waiting for Picture in Picture to start");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground &&
                ![self pipKeepsStreamAlive] && !self->_leavingStream) {
                Log(LOG_I, @"Picture in Picture didn't start: terminating stream for backgrounding");
                [self terminateForBackgrounding];
            }
        });
        return;
    }
#endif
    [self terminateForBackgrounding];
}

- (void)terminateForBackgrounding {
    Log(LOG_I, @"Terminating stream immediately for backgrounding");

    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
    
    [self returnToMainFrame];
}

- (void)edgeSwiped {
#if !TARGET_OS_TV
    // Starlight: the swipe pulls out the ••• button, which morphs into the stream menu past a threshold
    if ([self streamMenuVisible]) {
        return;
    }
    CGFloat translation = [_exitSwipeRecognizer translationInView:self.view].x;
    switch (_exitSwipeRecognizer.state) {
        case UIGestureRecognizerStateBegan:
            [self prepareStreamMenuOn:self];
            [_streamMenu dragChanged:translation];
            break;
        case UIGestureRecognizerStateChanged:
            [_streamMenu dragChanged:translation];
            break;
        case UIGestureRecognizerStateEnded: {
            CGFloat velocity = [_exitSwipeRecognizer velocityInView:self.view].x;
            Log(LOG_I, @"User swiped from the edge (%.0f pt)", translation);
            [_streamMenu dragEnded:translation predicted:translation + velocity * 0.25];
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [_streamMenu dragEnded:0 predicted:0];
            break;
        default:
            break;
    }
#else
    Log(LOG_I, @"User swiped to end stream");
    [self returnToMainFrame];
#endif
}

#if !TARGET_OS_TV
#pragma mark - Stream menu (Starlight)

- (void)streamMenuRequested {
    if ([self streamMenuVisible]) {
        [self hideStreamMenu];
    }
    else {
        [self showStreamMenu];
    }
}

- (BOOL)streamMenuVisible {
    return _streamMenu.isOpen;
}

- (void)streamMenuNavigate:(NSString*)action {
    [_streamMenu navigate:action];
}

// The menu lives for the whole stream (closed it's the ••• button): create it once, refresh what it
// shows, and put it in the given view controller (the device, the TV, or the second-screen page)
- (void)prepareStreamMenuOn:(UIViewController*)host {
    if (_streamMenu == nil) {
        _streamMenu = [[StarlightStreamMenu alloc] initWithGameName:self.streamConfig.appName ?: @"Game"
                                                       statsVisible:(_statsUpdateTimer != nil)];
        __weak StreamFrameViewController* weakSelf = self;
        _streamMenu.onAction = ^(NSString* action) {
            [weakSelf streamMenuAction:action];
        };
        _streamMenu.onSettings = ^(NSDictionary<NSString*, id>* values, BOOL reconnect) {
            [weakSelf streamMenuSettingsChanged:values reconnect:reconnect];
        };
    }
    [_streamMenu setStatsVisible:(_statsUpdateTimer != nil)];
    [_streamMenu setPictureInPictureAvailable:[self pipCanStartManually]];
    [_streamMenu setDisplayOption:[self displayMenuOption]];
    [_streamMenu setStreamSettings:[MainFrameViewController streamSettingsDictionaryForWindow:self.view.window]];
    
    UIViewController* menuVC = _streamMenu.viewController;
    if (menuVC.parentViewController != host) {
        if (menuVC.parentViewController != nil) {
            [menuVC willMoveToParentViewController:nil];
            [menuVC.view removeFromSuperview];
            [menuVC removeFromParentViewController];
        }
        [host addChildViewController:menuVC];
        menuVC.view.frame = host.view.bounds;
        menuVC.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host.view addSubview:menuVC.view];
        [menuVC didMoveToParentViewController:host];
    }
    else {
        [host.view bringSubviewToFront:menuVC.view];
    }
}

- (void)showStreamMenu {
    if ([self streamMenuVisible]) {
        return;
    }
    // With the stream on a TV the menu opens there, where you're looking (and you drive it with the controller);
    // a tap on the device's artwork opens it on the device instead
    UIViewController* host = _menuOnDevice && _companionVC != nil ? _companionVC
        : (_externalWindow != nil ? _externalWindow.rootViewController : self);
    _menuOnDevice = NO;
    [self prepareStreamMenuOn:host];
    [_streamMenu open];
}

// Alerts go over the second-screen page when it's showing
- (UIViewController*)alertPresenter {
    UIViewController* presenter = self;
    while (presenter.presentedViewController != nil && !presenter.presentedViewController.isBeingDismissed) {
        presenter = presenter.presentedViewController;
    }
    return presenter;
}

- (void)hideStreamMenu {
    if (![self streamMenuVisible]) {
        return;
    }
    // The panel shrinks back into the ••• button
    [_streamMenu close];
    // Opened on the TV or the second-screen page: come back to the device once the animation is done
    UIViewController* menuVC = _streamMenu.viewController;
    if (menuVC.parentViewController != self) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_streamMenu != nil && !self->_streamMenu.isOpen && menuVC.parentViewController != self) {
                [self prepareStreamMenuOn:self];
            }
        });
    }
}

- (void)streamMenuAction:(NSString*)action {
    if ([action isEqualToString:@"resume"]) {
        [self hideStreamMenu];
    }
    else if ([action isEqualToString:@"keyboard"]) {
        [self hideStreamMenu];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self->_streamView toggleKeyboard];
        });
    }
    else if ([action isEqualToString:@"stats"]) {
        if (_statsUpdateTimer != nil) {
            [_statsUpdateTimer invalidate];
            _statsUpdateTimer = nil;
            [self updateOverlayText:nil];
        }
        else {
            _statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                                 target:self
                                                               selector:@selector(updateStatsOverlay)
                                                               userInfo:nil
                                                                repeats:YES];
            [self updateStatsOverlay];
        }
        [_streamMenu setStatsVisible:(_statsUpdateTimer != nil)];
    }
    else if ([action isEqualToString:@"pip"]) {
        [self hideStreamMenu];
        [self startPictureInPicture];
    }
    else if ([action isEqualToString:@"display"]) {
        // Switch between the TV only and mirroring for the rest of this stream
        [self hideStreamMenu];
        _externalOverride = _externalWindow != nil ? 2 : 1;
        [self updateExternalDisplay];
    }
    else if ([action isEqualToString:@"disconnect"]) {
        [self hideStreamMenu];
        [self returnToMainFrame];
    }
    else if ([action isEqualToString:@"quit"]) {
        [self hideStreamMenu];
        // The main screen sends the quit request once the stream has closed
        UIViewController* root = self.navigationController.viewControllers.firstObject;
        if ([root isKindOfClass:[MainFrameViewController class]]) {
            [(MainFrameViewController*)root quitAppAfterStreamOnHostAddress:self.streamConfig.host];
        }
        [self returnToMainFrame];
    }
}
#endif

- (void) connectionStarted {
    Log(LOG_I, @"Connection started");
    dispatch_async(dispatch_get_main_queue(), ^{
        // Leave the spinner spinning until it's obscured by
        // the first frame of video.
        self->_stageLabel.hidden = YES;
        self->_tipLabel.hidden = YES;
        
        // Fade the game art out as the video takes over
        UIView* loadingBackground = self->_loadingBackground;
        self->_loadingBackground = nil;
        [UIView animateWithDuration:0.3 animations:^{
            loadingBackground.alpha = 0;
        } completion:^(BOOL finished) {
            [loadingBackground removeFromSuperview];
        }];
        
        [self->_streamView showOnScreenControls];
        
        [self->_controllerSupport connectionEstablished];
        
#if !TARGET_OS_TV
        // Starlight: show the ••• menu button for a few seconds so the menu is easy to find
        if (self->_externalWindow == nil) {
            [self prepareStreamMenuOn:self];
            [self->_streamMenu flashButton];
        }
#endif
        
#if !TARGET_OS_TV
        // Handoff: connected, so no more retries; offer this stream to the user's other devices
        self.streamConfig.handoffRetryUntil = nil;
        [self advertiseHandoff];
        
        // The stream may have changed screens while connecting
        self->_connectionReady = YES;
        [self checkStreamResolution];
#endif
        
        if (self->_settings.statsOverlay) {
            self->_statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                                       target:self
                                                                     selector:@selector(updateStatsOverlay)
                                                                     userInfo:nil
                                                                      repeats:YES];
        }
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %d", errorCode);
#if !TARGET_OS_TV
    if (_reconnecting) {
        // The old connection, stopped to reconnect
        return;
    }
#endif
    
    unsigned int portFlags = LiGetPortFlagsFromTerminationErrorCode(errorCode);
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portFlags);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* title;
        NSString* message;
        
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            title = @"Connection Error";
            message = @"Your device's network connection is blocking Moonlight. Streaming may not work while connected to this network.";
        }
        else {
            switch (errorCode) {
                case ML_ERROR_GRACEFUL_TERMINATION:
                    [self returnToMainFrame];
                    return;
                    
                case ML_ERROR_NO_VIDEO_TRAFFIC:
                    title = @"Connection Error";
                    message = @"No video received from host.";
                    if (portFlags != 0) {
                        char failingPorts[256];
                        LiStringifyPortFlags(portFlags, "\n", failingPorts, sizeof(failingPorts));
                        message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
                    }
                    break;
                    
                case ML_ERROR_NO_VIDEO_FRAME:
                    title = @"Connection Error";
                    message = @"Your network connection isn't performing well. Reduce your video bitrate setting or try a faster connection.";
                    break;
                    
                case ML_ERROR_UNEXPECTED_EARLY_TERMINATION:
                case ML_ERROR_PROTECTED_CONTENT:
                    title = @"Connection Error";
                    message = @"Something went wrong on your host PC when starting the stream.\n\nMake sure you don't have any DRM-protected content open on your host PC. You can also try restarting your host PC.\n\nIf the issue persists, try reinstalling your GPU drivers and GeForce Experience.";
                    break;
                    
                case ML_ERROR_FRAME_CONVERSION:
                    title = @"Connection Error";
                    message = @"The host PC reported a fatal video encoding error.\n\nTry disabling HDR mode, changing the streaming resolution, or changing your host PC's display resolution.";
                    break;
                    
                default:
                {
                    NSString* errorString;
                    if (abs(errorCode) > 1000) {
                        // We'll assume large errors are hex values
                        errorString = [NSString stringWithFormat:@"%08X", (uint32_t)errorCode];
                    }
                    else {
                        // Smaller values will just be printed as decimal (probably errno.h values)
                        errorString = [NSString stringWithFormat:@"%d", errorCode];
                    }
                    
                    title = @"Connection Terminated";
                    message = [NSString stringWithFormat: @"The connection was terminated\n\nError code: %@", errorString];
                    break;
                }
            }
        }
        
        UIAlertController* conTermAlert = [UIAlertController alertControllerWithTitle:title
                                                                              message:message
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:conTermAlert];
        [conTermAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [[self alertPresenter] presentViewController:conTermAlert animated:YES completion:nil];
    });

    [_streamMan stopStream];
}

- (void) stageStarting:(const char*)stageName {
    Log(LOG_I, @"Starting %s", stageName);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* lowerCase = [NSString stringWithFormat:@"%s in progress...", stageName];
        NSString* titleCase = [[[lowerCase substringToIndex:1] uppercaseString] stringByAppendingString:[lowerCase substringFromIndex:1]];
        [self->_stageLabel setText:titleCase];
        [self->_stageLabel sizeToFit];
        UIView* parent = self->_stageLabel.superview ?: self.view;
        self->_stageLabel.center = CGPointMake(parent.bounds.size.width / 2, self->_stageLabel.center.y);
    });
}

- (void) stageComplete:(const char*)stageName {
}

- (void) stageFailed:(const char*)stageName withError:(int)errorCode portTestFlags:(int)portTestFlags {
    Log(LOG_I, @"Stage %s failed: %d", stageName, errorCode);
#if !TARGET_OS_TV
    if (_reconnecting || [self retryHandoffResume]) {
        return;
    }
#endif
    
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portTestFlags);

    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* message = [NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode];
        if (portTestFlags != 0) {
            char failingPorts[256];
            LiStringifyPortFlags(portTestFlags, "\n", failingPorts, sizeof(failingPorts));
            message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
        }
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            message = [message stringByAppendingString:@"\n\nYour device's network connection is blocking Moonlight. Streaming may not work while connected to this network."];
        }
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Failed"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [[self alertPresenter] presentViewController:alert animated:YES completion:nil];
    });
    
    [_streamMan stopStream];
}

- (void) launchFailed:(NSString*)message {
    Log(LOG_I, @"Launch failed: %@", message);
#if !TARGET_OS_TV
    if (_reconnecting || [self retryHandoffResume]) {
        return;
    }
#endif
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Error"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [[self alertPresenter] presentViewController:alert animated:YES completion:nil];
    });
}

- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    Log(LOG_I, @"Rumble on gamepad %d: %04x %04x", controllerNumber, lowFreqMotor, highFreqMotor);
    
    [_controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

- (void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger {
    Log(LOG_I, @"Trigger rumble on gamepad %d: %04x %04x", controllerNumber, leftTrigger, rightTrigger);
    
    [_controllerSupport rumbleTriggers:controllerNumber leftTrigger:leftTrigger rightTrigger:rightTrigger];
}

- (void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz {
    Log(LOG_I, @"Set motion state on gamepad %d: %02x %u Hz", controllerNumber, motionType, reportRateHz);
    
    [_controllerSupport setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
}

- (void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b {
    Log(LOG_I, @"Set controller LED on gamepad %d: l%02x%02x%02x", controllerNumber, r, g, b);
    
    [_controllerSupport setControllerLed:controllerNumber r:r g:g b:b];
}

- (void)connectionStatusUpdate:(int)status {
    Log(LOG_W, @"Connection status update: %d", status);

    // The stats overlay takes precedence over these warnings
    if (_statsUpdateTimer != nil) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (status) {
            case CONN_STATUS_OKAY:
                [self updateOverlayText:nil];
                break;
                
            case CONN_STATUS_POOR:
                if (self->_streamConfig.bitRate > 5000) {
                    [self updateOverlayText:@"Slow connection to PC\nReduce your bitrate"];
                }
                else {
                    [self updateOverlayText:@"Poor connection to PC"];
                }
                break;
        }
    });
}

- (void) updatePreferredDisplayMode:(BOOL)streamActive {
#if TARGET_OS_TV
    if (@available(tvOS 11.2, *)) {
        UIWindow* window = [[[UIApplication sharedApplication] delegate] window];
        AVDisplayManager* displayManager = [window avDisplayManager];
        
        // This logic comes from Kodi and MrMC
        if (streamActive) {
            int dynamicRange;
            
            if (LiGetCurrentHostDisplayHdrMode()) {
                dynamicRange = 2; // HDR10
            }
            else {
                dynamicRange = 0; // SDR
            }
            
            AVDisplayCriteria* displayCriteria = [[AVDisplayCriteria alloc] initWithRefreshRate:[_settings.framerate floatValue]
                                                                              videoDynamicRange:dynamicRange];
            displayManager.preferredDisplayCriteria = displayCriteria;
        }
        else {
            // Switch back to the default display mode
            displayManager.preferredDisplayCriteria = nil;
        }
    }
#endif
}

- (void) setHdrMode:(bool)enabled {
    Log(LOG_I, @"HDR is now: %s", enabled ? "active" : "inactive");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updatePreferredDisplayMode:YES];
    });
}

- (void) videoContentShown {
    [_spinner stopAnimating];
    [self.view setBackgroundColor:[UIColor blackColor]];
#if !TARGET_OS_TV
    // Called on every IDR frame: also picks up a display layer recreated after a decoder error
    [self setupPictureInPicture];
#endif
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)gamepadPresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)mousePresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 14.0, *)) {
        [self setNeedsUpdateOfPrefersPointerLocked];
    }
#endif
}

- (void) streamExitRequested {
    Log(LOG_I, @"Gamepad combo requested stream exit");
    
    [self returnToMainFrame];
}

- (void)userInteractionBegan {
    // Disable hiding home bar when user is interacting.
    // iOS will force it to be shown anyway, but it will
    // also discard our edges deferring system gestures unless
    // we willingly give up home bar hiding preference.
    _userIsInteracting = YES;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)userInteractionEnded {
    // Enable home bar hiding again if conditions allow
    _userIsInteracting = NO;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

#if !TARGET_OS_TV
// Require a confirmation when streaming to activate a system gesture
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    // With the stream on the TV, the iPhone shows a normal interface
    return _externalWindow != nil ? UIRectEdgeNone : UIRectEdgeAll;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    if (_externalWindow != nil) {
        return NO;
    }
    if ([_controllerSupport getConnectedGamepadCount] > 0 &&
        [_streamView getCurrentOscState] == OnScreenControlsLevelOff &&
        _userIsInteracting == NO) {
        // Autohide the home bar when a gamepad is connected
        // and the on-screen controls are disabled. We can't
        // do this all the time because any touch on the display
        // will cause the home indicator to reappear, and our
        // preferredScreenEdgesDeferringSystemGestures will also
        // be suppressed (leading to possible errant exits of the
        // stream).
        return YES;
    }
    
    return NO;
}

- (BOOL)shouldAutorotate {
    return YES;
}

// Starlight: no system status bar over the stream
- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)prefersPointerLocked {
    // Pointer lock breaks the UIKit mouse APIs, which is a problem because
    // GCMouse is horribly broken on iOS 14.0 for certain mice. Only lock
    // the cursor if there is a GCMouse present.
    return [GCMouse mice].count > 0;
}
#endif


#if !TARGET_OS_TV
#pragma mark - Picture in Picture (Starlight)

- (BOOL)pipSettingEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"StarlightPiPEnabled"];
}

- (BOOL)pipAutoStartEnabled {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:@"StarlightPiPAuto"];
    return value == nil ? YES : [value boolValue];
}

- (BOOL)pipKeepsStreamAlive {
    return _pipStarting || _pipActive;
}

- (BOOL)pipCanStartAutomatically {
    if (@available(iOS 15.0, *)) {
        AVPictureInPictureController* pip = _pipController;
        return pip != nil && pip.canStartPictureInPictureAutomaticallyFromInline;
    }
    return NO;
}

- (BOOL)pipCanStartManually {
    if (@available(iOS 15.0, *)) {
        AVPictureInPictureController* pip = _pipController;
        return pip != nil && !pip.isPictureInPictureActive;
    }
    return NO;
}

- (AVSampleBufferDisplayLayer*)currentDisplayLayer {
    for (CALayer* layer in _streamView.layer.sublayers) {
        if ([layer isKindOfClass:[AVSampleBufferDisplayLayer class]]) {
            return (AVSampleBufferDisplayLayer*)layer;
        }
    }
    return nil;
}

- (void)setupPictureInPicture {
    // Not while the stream is on the TV: it can't be in two places
    if (![self pipSettingEnabled] || _externalWindow != nil || _leavingStream) {
        return;
    }
    if (@available(iOS 15.0, *)) {
        if (![AVPictureInPictureController isPictureInPictureSupported]) {
            return;
        }
        AVSampleBufferDisplayLayer* layer = [self currentDisplayLayer];
        if (layer == nil) {
            return;
        }
        AVPictureInPictureController* pip = _pipController;
        if (pip != nil && pip.contentSource.sampleBufferDisplayLayer == layer) {
            return;
        }
        AVPictureInPictureControllerContentSource* source =
            [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:layer
                                                                               playbackDelegate:self];
        if (pip != nil) {
            // The renderer recreated its layer (decoder error): point PiP at the new one
            pip.contentSource = source;
            return;
        }
        pip = [[AVPictureInPictureController alloc] initWithContentSource:source];
        pip.delegate = self;
        pip.requiresLinearPlayback = YES;
        pip.canStartPictureInPictureAutomaticallyFromInline = [self pipAutoStartEnabled];
        _pipController = pip;
        Log(LOG_I, @"Picture in Picture ready (automatic start: %d)", [self pipAutoStartEnabled]);
    }
}

- (void)startPictureInPicture {
    if (@available(iOS 15.0, *)) {
        AVPictureInPictureController* pip = _pipController;
        if (pip != nil && pip.isPictureInPicturePossible) {
            [pip startPictureInPicture];
        }
        else {
            Log(LOG_W, @"Picture in Picture isn't possible right now");
        }
    }
}

- (void)tearDownPictureInPicture {
    if (@available(iOS 15.0, *)) {
        AVPictureInPictureController* pip = _pipController;
        _pipController = nil;
        if (pip != nil) {
            pip.delegate = nil;
            if (pip.isPictureInPictureActive) {
                [pip stopPictureInPicture];
            }
        }
    }
    _pipStarting = NO;
    _pipActive = NO;
}

// AVPictureInPictureSampleBufferPlaybackDelegate: a live stream, never paused, no timeline

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController setPlaying:(BOOL)playing API_AVAILABLE(ios(15.0)) {
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)pictureInPictureController API_AVAILABLE(ios(15.0)) {
    return CMTimeRangeMake(kCMTimeNegativeInfinity, kCMTimePositiveInfinity);
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)pictureInPictureController API_AVAILABLE(ios(15.0)) {
    return NO;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController didTransitionToRenderSize:(CMVideoDimensions)newRenderSize API_AVAILABLE(ios(15.0)) {
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController skipByInterval:(CMTime)skipInterval completionHandler:(void (^)(void))completionHandler API_AVAILABLE(ios(15.0)) {
    completionHandler();
}

// AVPictureInPictureControllerDelegate

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    Log(LOG_I, @"Picture in Picture starting");
    _pipStarting = YES;
    [self hideStreamMenu];
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    _pipStarting = NO;
    _pipActive = YES;
    // The stream continues in the background: don't let the inactivity timer end it
    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
    Log(LOG_W, @"Picture in Picture failed to start: %@", error);
    _pipStarting = NO;
    _pipActive = NO;
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground && !_leavingStream) {
        [self terminateForBackgrounding];
    }
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    // The user tapped the button to go back to the full-screen stream
    _pipRestoring = YES;
    completionHandler(YES);
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    BOOL restoring = _pipRestoring;
    _pipRestoring = NO;
    _pipActive = NO;
    _pipStarting = NO;
    if (!restoring && !_leavingStream &&
        [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        // The PiP window was closed while Starlight is in the background: end the stream
        Log(LOG_I, @"Picture in Picture closed: ending the stream");
        [self terminateForBackgrounding];
    }
}

#pragma mark - External display (Starlight)

// 0 = Mirror (iOS default), 1 = Second Screen
- (NSInteger)externalDisplayMode {
    return [[NSUserDefaults standardUserDefaults] integerForKey:@"StarlightExternalDisplayMode"];
}

- (UIWindowScene*)connectedExternalScene {
    UIWindowScene* scene = [StarlightSceneDelegate externalDisplayScene];
    if (scene == nil || scene.activationState == UISceneActivationStateUnattached) {
        return nil;
    }
    return scene;
}

- (void)externalScreensChanged:(NSNotification*)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateExternalDisplay];
        [self->_streamMenu setDisplayOption:[self displayMenuOption]];
    });
}

// Stream menu: 0 = no TV, 1 = mirroring (offer External Display), 2 = on the TV (offer Mirror Display)
- (NSInteger)displayMenuOption {
    if ([self connectedExternalScene] == nil) {
        return 0;
    }
    return _externalWindow != nil ? 2 : 1;
}

- (BOOL)wantsSecondScreen {
    if (_externalOverride != 0) {
        return _externalOverride == 1;
    }
    return [self externalDisplayMode] == 1;
}

- (void)updateExternalDisplay {
    if (_leavingStream) {
        return;
    }
    UIWindowScene* scene = [self wantsSecondScreen] ? [self connectedExternalScene] : nil;
    if (scene != nil && _externalWindow == nil) {
        [self attachToExternalScene:scene];
    }
    else if (scene == nil && _externalWindow != nil) {
        [self detachFromExternalScreen];
    }
    [self checkStreamResolution];
}

// The view that holds the video: the zoomable scroll view in touchscreen mode, else the stream view
- (UIView*)streamContainer {
    return _scrollView != nil ? (UIView*)_scrollView : (UIView*)_streamView;
}

- (void)moveStreamContainerTo:(UIView*)parent frame:(CGRect)frame atBottom:(BOOL)atBottom {
    UIView* container = [self streamContainer];
    [container removeFromSuperview];
    if (_scrollView != nil) {
        _scrollView.zoomScale = 1.0;
    }
    container.frame = frame;
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (_scrollView != nil) {
        _streamView.frame = _scrollView.bounds;
    }
    if (atBottom) {
        [parent insertSubview:container atIndex:0];
    }
    else {
        [parent addSubview:container];
    }
    [self layoutDisplayLayer];
}

// Same sizing rule as VideoDecoderRenderer: fit the stream's aspect ratio inside the view
- (void)layoutDisplayLayer {
    AVSampleBufferDisplayLayer* layer = [self currentDisplayLayer];
    if (layer == nil || self.streamConfig.height == 0) {
        return;
    }
    CGRect bounds = _streamView.bounds;
    CGFloat aspect = (CGFloat)self.streamConfig.width / (CGFloat)self.streamConfig.height;
    CGSize size;
    if (bounds.size.width > bounds.size.height * aspect) {
        size = CGSizeMake(bounds.size.height * aspect, bounds.size.height);
    }
    else {
        size = CGSizeMake(bounds.size.width, bounds.size.width / aspect);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.position = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    layer.bounds = CGRectMake(0, 0, size.width, size.height);
    [CATransaction commit];
}

- (void)attachToExternalScene:(UIWindowScene*)scene {
    UIScreen* screen = scene.screen;
    Log(LOG_I, @"External display connected (%.0fx%.0f): moving the stream to the TV",
        screen.bounds.size.width, screen.bounds.size.height);
    
    // Picture in Picture needs the video on the iPhone; the stream menu reopens on the TV
    [self tearDownPictureInPicture];
    [self hideStreamMenu];
    
    screen.overscanCompensation = UIScreenOverscanCompensationNone;
    UIWindow* window = [[UIWindow alloc] initWithWindowScene:scene];
    window.frame = scene.coordinateSpace.bounds;
    // A GCEventViewController (UIKit interaction off), like this screen: with GCSupportsControllerUserInteraction
    // on, a plain view controller would let UIKit take the controller and the game would stop getting it
    GCEventViewController* root = [[GCEventViewController alloc] init];
    root.controllerUserInteractionEnabled = NO;
    root.view.backgroundColor = [UIColor blackColor];
    window.rootViewController = root;
    window.hidden = NO;
    _externalWindow = window;
    
    [self moveStreamContainerTo:root.view frame:window.bounds atBottom:NO];
    // Second Screen: no touch controls drawn over the game on the TV
    [_streamView setOnScreenControlsSuppressed:YES];
    [self showCompanionPanel];
    
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
}

- (void)detachFromExternalScreen {
    Log(LOG_I, @"Moving the stream back to the device");
    [self hideStreamMenu];
    [self hideCompanionPanel];
    [self moveStreamContainerTo:self.view frame:self.view.bounds atBottom:YES];
    _externalWindow.hidden = YES;
    _externalWindow = nil;
    // Back on the device (or mirroring): touch controls as set in Settings
    [_streamView setOnScreenControlsSuppressed:NO];
    
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    [self setupPictureInPicture];
}

// Stream is ending: just let go of the TV (iOS goes back to mirroring)
- (void)tearDownExternalDisplay {
    if (_externalWindow == nil) {
        return;
    }
    [self hideStreamMenu];
    [self hideCompanionPanel];
    _externalWindow.hidden = YES;
    _externalWindow = nil;
}

// On the device while the stream plays on the TV: the game's artwork, full screen, nothing else.
// A tap opens the stream menu on the device.
- (void)showCompanionPanel {
    // Can only present once this screen is on screen (viewDidAppear calls this again)
    if (_companionVC != nil || self.view.window == nil) {
        return;
    }
    // Same as the TV window: the controller must keep going to the game, not to UIKit
    GCEventViewController* page = [[GCEventViewController alloc] init];
    page.controllerUserInteractionEnabled = NO;
    page.view.backgroundColor = [UIColor blackColor];
    
    SteamGridDBManager* sgdb = [SteamGridDBManager sharedManager];
    NSString* appName = self.streamConfig.appName ?: @"";
    NSString* path = [sgdb cachedPathForAppName:appName kind:SteamGridDBKindHero]
        ?: [sgdb cachedPathForAppName:appName kind:SteamGridDBKindGrid];
    UIImage* image = path != nil ? [UIImage imageWithContentsOfFile:path] : nil;
    if (image != nil) {
        UIImageView* art = [[UIImageView alloc] initWithFrame:page.view.bounds];
        art.image = image;
        art.contentMode = UIViewContentModeScaleAspectFill;
        art.clipsToBounds = YES;
        art.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        art.accessibilityLabel = [NSString stringWithFormat:@"%@, playing on the TV", appName];
        [page.view addSubview:art];
    }
    [page.view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(companionTapped)]];
    
    // Presented full screen, so it fills the device whatever the stream view's geometry
    page.modalPresentationStyle = UIModalPresentationOverFullScreen;
    page.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    _companionVC = page;
    [[self alertPresenter] presentViewController:page animated:YES completion:nil];
}

- (void)companionTapped {
    if ([self streamMenuVisible]) {
        return;
    }
    _menuOnDevice = YES;
    [self showStreamMenu];
}

- (void)hideCompanionPanel {
    if (_companionVC == nil) {
        return;
    }
    UIViewController* page = _companionVC;
    _companionVC = nil;
    if (page.presentingViewController != nil) {
        [page.presentingViewController dismissViewControllerAnimated:NO completion:nil];
    }
}
#endif

@end
