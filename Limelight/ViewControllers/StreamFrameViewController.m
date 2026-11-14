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
#if !TARGET_OS_TV
#import "SteamGridDBManager.h"
#endif

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <Limelight.h>

#if !TARGET_OS_TV
#import <AVKit/AVKit.h>
@import GameController;
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
    
    // Starlight: second screen (stream on the TV, companion panel on the iPhone)
    UIWindow *_externalWindow;
    StarlightCompanionPanel *_companion;
    BOOL _externalSuppressed;
#endif
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
#if !TARGET_OS_TV
    [[self revealViewController] setPrimaryViewController:self];
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
    [_tipLabel setText:@"Tip: Swipe from the left edge or hold Start + Select for the stream menu"];
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
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(externalScreensChanged:)
                                                 name:UIScreenDidConnectNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(externalScreensChanged:)
                                                 name:UIScreenDidDisconnectNotification
                                               object:nil];
    
    if ([self pipSettingEnabled] && [self pipControllerInputEnabled]) {
        if (@available(iOS 14.5, *)) {
            // Keep reading the controller while the stream plays in Picture in Picture
            GCController.shouldMonitorBackgroundEvents = YES;
        }
    }
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
    SteamGridDBManager* sgdb = [SteamGridDBManager sharedManager];
    NSString* backgroundPath = [sgdb cachedPathForAppName:self.streamConfig.appName kind:SteamGridDBKindHero]
        ?: [sgdb cachedPathForAppName:self.streamConfig.appName kind:SteamGridDBKindGrid];
    UIImage* background = backgroundPath != nil ? [UIImage imageWithContentsOfFile:backgroundPath] : nil;
    _loadingBackground = [[UIView alloc] initWithFrame:self.view.bounds];
    _loadingBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _loadingBackground.userInteractionEnabled = NO;
    _loadingBackground.backgroundColor = [UIColor blackColor];
    if (background != nil) {
        UIImageView* backgroundView = [[UIImageView alloc] initWithFrame:_loadingBackground.bounds];
        backgroundView.image = background;
        backgroundView.contentMode = UIViewContentModeScaleAspectFill;
        backgroundView.clipsToBounds = YES;
        backgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_loadingBackground addSubview:backgroundView];
        
        UIView* dim = [[UIView alloc] initWithFrame:_loadingBackground.bounds];
        dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_loadingBackground addSubview:dim];
    }
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

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _streamView;
}

- (void)willMoveToParentViewController:(UIViewController *)parent {
    // Only cleanup when we're being destroyed
    if (parent == nil) {
#if !TARGET_OS_TV
        [self tearDownPictureInPicture];
        [self tearDownExternalDisplay];
        if (@available(iOS 14.5, *)) {
            GCController.shouldMonitorBackgroundEvents = NO;
        }
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
        [self.view addSubview:_overlayView];
    }
    
    if (text != nil) {
        // We set our bounds to the maximum width in order to work around a bug where
        // sizeToFit interacts badly with the UITextView's line breaks, causing the
        // width to get smaller and smaller each time as more line breaks are inserted.
        [_overlayView setBounds:CGRectMake(self.view.frame.origin.x,
                                           _overlayView.frame.origin.y,
                                           self.view.frame.size.width,
                                           _overlayView.frame.size.height)];
        [_overlayView setText:text];
        [_overlayView sizeToFit];
        [_overlayView setCenter:CGPointMake(self.view.frame.size.width / 2, _overlayView.frame.size.height / 2)];
        [_overlayView setHidden:NO];
    }
    else {
        [_overlayView setHidden:YES];
    }
}

- (void) returnToMainFrame {
#if !TARGET_OS_TV
    _leavingStream = YES;
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
    // Starlight: open the stream menu instead of disconnecting right away
    if (_exitSwipeRecognizer.state == UIGestureRecognizerStateBegan) {
        Log(LOG_I, @"User swiped from the edge: showing the stream menu");
        [self showStreamMenu];
    }
#else
    Log(LOG_I, @"User swiped to end stream");
    [self returnToMainFrame];
#endif
}

#if !TARGET_OS_TV
#pragma mark - Stream menu (Starlight)

- (void)streamMenuRequested {
    if (_streamMenu != nil) {
        [self hideStreamMenu];
    }
    else {
        [self showStreamMenu];
    }
}

- (BOOL)streamMenuVisible {
    return _streamMenu != nil;
}

- (void)streamMenuNavigate:(NSString*)action {
    [_streamMenu navigate:action];
}

- (void)showStreamMenu {
    if (_streamMenu != nil) {
        return;
    }
    _streamMenu = [[StarlightStreamMenu alloc] initWithGameName:self.streamConfig.appName ?: @"Game"
                                                   statsVisible:(_statsUpdateTimer != nil)];
    [_streamMenu setPictureInPictureAvailable:[self pipCanStartManually]];
    __weak StreamFrameViewController* weakSelf = self;
    _streamMenu.onAction = ^(NSString* action) {
        [weakSelf streamMenuAction:action];
    };
    
    UIViewController* menuVC = _streamMenu.viewController;
    [self addChildViewController:menuVC];
    menuVC.view.frame = self.view.bounds;
    menuVC.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:menuVC.view];
    [menuVC didMoveToParentViewController:self];
}

- (void)hideStreamMenu {
    if (_streamMenu == nil) {
        return;
    }
    UIViewController* menuVC = _streamMenu.viewController;
    _streamMenu = nil;
    [UIView animateWithDuration:0.2 animations:^{
        menuVC.view.alpha = 0;
    } completion:^(BOOL finished) {
        [menuVC willMoveToParentViewController:nil];
        [menuVC.view removeFromSuperview];
        [menuVC removeFromParentViewController];
    }];
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
        [self presentViewController:conTermAlert animated:YES completion:nil];
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
        self->_stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self->_stageLabel.center.y);
    });
}

- (void) stageComplete:(const char*)stageName {
}

- (void) stageFailed:(const char*)stageName withError:(int)errorCode portTestFlags:(int)portTestFlags {
    Log(LOG_I, @"Stage %s failed: %d", stageName, errorCode);
    
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
        [self presentViewController:alert animated:YES completion:nil];
    });
    
    [_streamMan stopStream];
}

- (void) launchFailed:(NSString*)message {
    Log(LOG_I, @"Launch failed: %@", message);
    
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
        [self presentViewController:alert animated:YES completion:nil];
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

- (BOOL)pipControllerInputEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"StarlightPiPControllerInput"];
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

- (UIScreen*)connectedExternalScreen {
    for (UIScreen* screen in [UIScreen screens]) {
        if (screen != [UIScreen mainScreen]) {
            return screen;
        }
    }
    return nil;
}

- (void)externalScreensChanged:(NSNotification*)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateExternalDisplay];
    });
}

- (void)updateExternalDisplay {
    if (_leavingStream) {
        return;
    }
    UIScreen* screen = ([self externalDisplayMode] == 1 && !_externalSuppressed) ? [self connectedExternalScreen] : nil;
    if (screen != nil && _externalWindow == nil) {
        [self attachToExternalScreen:screen];
    }
    else if (screen == nil && _externalWindow != nil) {
        [self detachFromExternalScreen];
    }
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

- (void)attachToExternalScreen:(UIScreen*)screen {
    Log(LOG_I, @"External display connected (%.0fx%.0f): moving the stream to the TV",
        screen.bounds.size.width, screen.bounds.size.height);
    
    // Picture in Picture needs the video on the iPhone
    [self tearDownPictureInPicture];
    
    screen.overscanCompensation = UIScreenOverscanCompensationNone;
    UIWindow* window = [[UIWindow alloc] initWithFrame:screen.bounds];
    window.screen = screen;
    UIViewController* root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor blackColor];
    window.rootViewController = root;
    window.hidden = NO;
    _externalWindow = window;
    
    [self moveStreamContainerTo:root.view frame:window.bounds atBottom:NO];
    [self showCompanionPanel];
    
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
}

- (void)detachFromExternalScreen {
    Log(LOG_I, @"Moving the stream back to the iPhone");
    [self hideCompanionPanel];
    [self moveStreamContainerTo:self.view frame:self.view.bounds atBottom:YES];
    _externalWindow.hidden = YES;
    _externalWindow = nil;
    
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    [self setupPictureInPicture];
}

// Stream is ending: just let go of the TV (iOS goes back to mirroring)
- (void)tearDownExternalDisplay {
    if (_externalWindow == nil) {
        return;
    }
    [self hideCompanionPanel];
    _externalWindow.hidden = YES;
    _externalWindow = nil;
}

- (NSInteger)steamAppIdForStream {
    NSString* host = self.streamConfig.hostUUID;
    NSString* app = self.streamConfig.appID;
    if (host != nil && app != nil) {
        NSDictionary* ids = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"StarlightSteamAppIds"];
        NSNumber* appid = ids[[NSString stringWithFormat:@"%@|%@", host, app]];
        if (appid != nil) {
            return appid.integerValue;
        }
    }
    return 0;
}

- (void)showCompanionPanel {
    if (_companion != nil) {
        return;
    }
    SteamGridDBManager* sgdb = [SteamGridDBManager sharedManager];
    NSString* appName = self.streamConfig.appName ?: @"Game";
    NSString* heroPath = [sgdb cachedPathForAppName:appName kind:SteamGridDBKindHero]
        ?: [sgdb cachedPathForAppName:appName kind:SteamGridDBKindGrid];
    _companion = [[StarlightCompanionPanel alloc] initWithGameName:appName
                                                        steamAppId:[self steamAppIdForStream]
                                                          heroPath:heroPath];
    __weak StreamFrameViewController* weakSelf = self;
    _companion.onAction = ^(NSString* action) {
        [weakSelf companionAction:action];
    };
    UIViewController* panelVC = _companion.viewController;
    [self addChildViewController:panelVC];
    panelVC.view.frame = self.view.bounds;
    panelVC.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (_streamMenu != nil) {
        // Keep the stream menu on top
        [self.view insertSubview:panelVC.view belowSubview:_streamMenu.viewController.view];
    }
    else {
        [self.view addSubview:panelVC.view];
    }
    [panelVC didMoveToParentViewController:self];
}

- (void)hideCompanionPanel {
    if (_companion == nil) {
        return;
    }
    UIViewController* panelVC = _companion.viewController;
    _companion = nil;
    [panelVC willMoveToParentViewController:nil];
    [panelVC.view removeFromSuperview];
    [panelVC removeFromParentViewController];
}

- (void)companionAction:(NSString*)action {
    if ([action isEqualToString:@"iphone"]) {
        // Back to the iPhone for the rest of this stream (iOS mirrors the TV again)
        _externalSuppressed = YES;
        [self detachFromExternalScreen];
    }
    else if ([action isEqualToString:@"disconnect"] || [action isEqualToString:@"quit"]) {
        [self streamMenuAction:action];
    }
}
#endif

@end
