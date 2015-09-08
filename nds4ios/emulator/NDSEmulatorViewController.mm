//
//  NDSEmulatorViewController.m
//  nds4ios
//
//  Created by InfiniDev on 6/11/13.
//  Copyright (c) 2013 InfiniDev. All rights reserved.
//

#import "AppDelegate.h"
#import "NDSEmulatorViewController.h"
#import "GLProgram.h"
#import "UIScreen+Widescreen.h"

#import <GLKit/GLKit.h>
#import <OpenGLES/ES2/gl.h>

#include "emu.h"

#define STRINGIZE(x) #x
#define STRINGIZE2(x) STRINGIZE(x)
#define SHADER_STRING(text) @ STRINGIZE2(text)

NSString *const kVertShader = SHADER_STRING
(
 attribute vec4 position;
 attribute vec2 inputTextureCoordinate;
 
 varying highp vec2 texCoord;
 
 void main()
 {
     texCoord = inputTextureCoordinate;
     gl_Position = position;
 }
 );

NSString *const kFragShader = SHADER_STRING
(
 uniform sampler2D inputImageTexture;
 varying highp vec2 texCoord;
 
 void main()
 {
     highp vec4 color = texture2D(inputImageTexture, texCoord);
     gl_FragColor = color;
 }
 );

const float positionVert[] =
{
    -1.0f, 1.0f,
    1.0f, 1.0f,
    -1.0f, -1.0f,
    1.0f, -1.0f
};

const float textureVert[] =
{
    0.0f, 0.0f,
    1.0f, 0.0f,
    0.0f, 1.0f,
    1.0f, 1.0f
};

@interface NDSEmulatorViewController () <GLKViewDelegate> {
    int fps;
    
    GLuint texHandle;
    GLint attribPos;
    GLint attribTexCoord;
    GLint texUniform;
}

@property (weak, nonatomic) IBOutlet UILabel *fpsLabel;
@property (weak, nonatomic) IBOutlet UILabel *timeLabel;
@property (weak, nonatomic) IBOutlet UILabel *batteryLabel;
@property (strong, nonatomic) GLProgram *program;
@property (strong, nonatomic) EAGLContext *context;
@property (strong, nonatomic) IBOutlet GLKView *glkView;
@property (weak, nonatomic) IBOutlet UIView *controllerContainerView;

@property (weak, nonatomic) IBOutlet NDSDirectionalControl *directionalControl;
@property (weak, nonatomic) IBOutlet NDSButtonControl *buttonControl;
@property (weak, nonatomic) IBOutlet UIButton *dismissButton;
@property (weak, nonatomic) IBOutlet UIButton *startButton;
@property (weak, nonatomic) IBOutlet UIButton *selectButton;
@property (strong, nonatomic) UIImageView *snapshotView;

- (IBAction)hideEmulator:(id)sender;
- (IBAction)onButtonUp:(UIControl*)sender;
- (IBAction)onButtonDown:(UIControl*)sender;

@end

@implementation NDSEmulatorViewController
{
    NSLock *emuLoopLock;
}

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        // Custom initialization
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view.
    
    self.view.multipleTouchEnabled = YES;
    
    [self loadROM];
    
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter addObserver:self selector:@selector(pauseEmulation) name:UIApplicationWillResignActiveNotification object:nil];
    [notificationCenter addObserver:self selector:@selector(resumeEmulation) name:UIApplicationDidBecomeActiveNotification object:nil];
    [notificationCenter addObserver:self selector:@selector(defaultsChanged:) name:NSUserDefaultsDidChangeNotification object:nil];
    
    UIDevice *currentDevice = [UIDevice currentDevice];
    currentDevice.batteryMonitoringEnabled = YES;
    
    [self defaultsChanged:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [UIApplication sharedApplication].statusBarHidden = YES;
}

- (void)viewWillDisappear:(BOOL)animated {
    [UIApplication sharedApplication].statusBarHidden = NO;
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)defaultsChanged:(NSNotification*)notification
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    EMU_setFrameSkip([defaults integerForKey:@"frameSkip"]);
    EMU_enableSound(![defaults boolForKey:@"disableSound"]);
    
    self.directionalControl.style = [defaults integerForKey:@"controlPadStyle"];
    
    [self viewWillLayoutSubviews];
    
    // Purposefully commented out line below, as we don't want to be able to switch CPU modes in the middle of emulation
    // EMU_setCPUMode([defaults boolForKey:@"enableJIT"] ? 2 : 1);
    
    
    self.fpsLabel.hidden = ![defaults integerForKey:@"showFPS"];
}

- (void)viewWillLayoutSubviews
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL isLandscape = self.view.bounds.size.width > self.view.bounds.size.height;
    BOOL isWidescreen = [[UIScreen mainScreen] isWidescreen];
    
    self.glkView.frame = [self rectForScreenView];
    self.snapshotView.frame = [self rectForScreenView];
    if (isLandscape) {
        self.controllerContainerView.frame = self.view.bounds;
        self.dismissButton.frame = CGRectMake((self.view.bounds.size.width + self.view.bounds.size.height/1.5)/2 + 8, 8, 28, 28);
        self.directionalControl.center = CGPointMake(66, self.view.bounds.size.height-128);
        self.buttonControl.center = CGPointMake(self.view.bounds.size.width-66, self.view.bounds.size.height-128);
        self.startButton.center = CGPointMake(self.view.bounds.size.width-102, self.view.bounds.size.height-48);
        self.selectButton.center = CGPointMake(self.view.bounds.size.width-102, self.view.bounds.size.height-16);
        self.controllerContainerView.alpha = self.dismissButton.alpha = 1.0;
        self.fpsLabel.frame = CGRectMake(70, 0, 70, 24);
        self.timeLabel.frame = CGRectMake(69, 35, 72, 24);
        self.batteryLabel.frame = CGRectMake(CGRectGetWidth(self.view.frame) - 69 - 72 - 30, 35, 95, 24);
    } else {
        self.controllerContainerView.frame = CGRectMake(0, [defaults integerForKey:@"controlPosition"] == 0 ? 0 : 240 + (88 * isWidescreen), 320, 240);
        self.dismissButton.frame = CGRectMake(146, 0, 28, 28);
        self.directionalControl.center = CGPointMake(60, 172);
        self.buttonControl.center = CGPointMake(self.view.bounds.size.width-60, 172);
        self.startButton.center = CGPointMake(187, 228);
        self.selectButton.center = CGPointMake(133, 228);
        self.controllerContainerView.alpha = self.dismissButton.alpha = MAX(0.1, [defaults floatForKey:@"controlOpacity"]);
        self.fpsLabel.frame = CGRectMake(6, 0, 70, 24);
        self.timeLabel.frame = CGRectMake(32, 0, 70, 24);
    }
}

- (CGRect)rectForScreenView
{
    BOOL isLandscape = self.view.bounds.size.width > self.view.bounds.size.height;
    if (isLandscape) {
        return CGRectMake(self.view.bounds.size.width - (self.view.bounds.size.width + self.view.bounds.size.height/1.5)/2, 0, self.view.bounds.size.height/1.5, self.view.bounds.size.height);
    } else {
        return CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.width*1.5);
    }
}

#pragma mark - Playing ROM

- (void)loadROM {
    EMU_setWorkingDir([[self.romFilepath stringByDeletingLastPathComponent] UTF8String]);
    EMU_init();
    EMU_setCPUMode([[NSUserDefaults standardUserDefaults] boolForKey:@"enableJIT"] ? 2 : 1);
    EMU_loadRom([self.romFilepath UTF8String]);
    EMU_change3D(1);
        
    [self initGL];
    
    emuLoopLock = [NSLock new];
    
    [self startEmulatorLoop];
}

- (void)initGL
{
    self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    [EAGLContext setCurrentContext:self.context];
    
    CGRect frame = [self rectForScreenView];
    
    self.glkView = [[GLKView alloc] initWithFrame:frame context:self.context];
    self.glkView.delegate = self;
    [self.view insertSubview:self.glkView atIndex:0];
    
    self.program = [[GLProgram alloc] initWithVertexShaderString:kVertShader fragmentShaderString:kFragShader];
    
    [self.program addAttribute:@"position"];
	[self.program addAttribute:@"inputTextureCoordinate"];
    
    [self.program link];
    
    attribPos = [self.program attributeIndex:@"position"];
    attribTexCoord = [self.program attributeIndex:@"inputTextureCoordinate"];
    
    texUniform = [self.program uniformIndex:@"inputImageTexture"];
    
    glEnableVertexAttribArray(attribPos);
    glEnableVertexAttribArray(attribTexCoord);
    
    float scale = [UIScreen mainScreen].scale;
    CGSize size = CGSizeMake(self.glkView.bounds.size.width * scale, self.glkView.bounds.size.height * scale);
    
    glViewport(0, 0, size.width, size.height);
    
    [self.program use];
    
    glGenTextures(1, &texHandle);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, texHandle);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

- (void)shutdownGL
{
    glDeleteTextures(1, &texHandle);
    texHandle = 0;
    self.context = nil;
    self.program = nil;
    [self.glkView removeFromSuperview];
    self.glkView = nil;
    [EAGLContext setCurrentContext:nil];
}

- (UIImage*)screenSnapshot
{
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CFDataRef videoData = CFDataCreate(NULL, (UInt8*)video.buffer, video.size()*4);
    CGDataProviderRef dataProvider = CGDataProviderCreateWithCFData(videoData);
    CGImageRef screenImage = CGImageCreate(256, 384, 8, 32, 256*4, colorSpace, kCGBitmapByteOrderDefault, dataProvider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(dataProvider);
    CFRelease(videoData);
    
    UIImage *image = [UIImage imageWithCGImage:screenImage];
    CGImageRelease(screenImage);
    return image;
}

- (void)pauseEmulation
{
    if (!execute) return;
    // save snapshot of screen
    if (self.snapshotView == nil) {
        self.snapshotView = [[UIImageView alloc] initWithFrame:self.glkView.frame];
        [self.view insertSubview:self.snapshotView aboveSubview:self.glkView];
    } else {
        self.snapshotView.hidden = NO;
    }
    self.snapshotView.image = [self screenSnapshot];
    
    // pause emulation
    EMU_pause(true);
    [emuLoopLock lock]; // make sure emulator loop has ended
    [emuLoopLock unlock];
    [self shutdownGL];
}

- (void)resumeEmulation
{
    if (self.presentingViewController.presentedViewController != self) return;
    if (execute) return;
    // remove snapshot
    self.snapshotView.hidden = YES;
    
    // resume emulation
    [self initGL];
    EMU_pause(false);
    [self startEmulatorLoop];
}

- (void)startEmulatorLoop
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [emuLoopLock lock];
        while (execute) {
            EMU_runCore();
            fps = EMU_runOther();
            EMU_copyMasterBuffer();
            
            [self updateDisplay];
        }
        [emuLoopLock unlock];
    });
}

- (void)updateDisplay
{
    if (texHandle == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.fpsLabel.text = [NSString stringWithFormat:@"%d FPS",fps];
        NSDate *senddate = [NSDate date];
        NSDateFormatter *dateformatter = [[NSDateFormatter alloc] init];
        [dateformatter setDateFormat:@"HH:mm:ss"];
        self.timeLabel.text = [dateformatter stringFromDate:senddate];
        UIDevice *device = [UIDevice currentDevice];
        self.batteryLabel.text = [NSString stringWithFormat:@"电量%d%%", int(round(device.batteryLevel * 100))];
        
    });
    
    glBindTexture(GL_TEXTURE_2D, texHandle);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 256, 384, 0, GL_RGBA, GL_UNSIGNED_BYTE, &video.buffer);
    
    [self.glkView display];
}

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect
{
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, texHandle);
    glUniform1i(texUniform, 1);
    
    glVertexAttribPointer(attribPos, 2, GL_FLOAT, 0, 0, (const GLfloat*)&positionVert);
    glVertexAttribPointer(attribTexCoord, 2, GL_FLOAT, 0, 0, (const GLfloat*)&textureVert);
    
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

#pragma mark - Controls

- (IBAction)pressedDPad:(NDSDirectionalControl *)sender
{
    NDSDirectionalControlDirection state = sender.direction;
    EMU_setDPad(state & NDSDirectionalControlDirectionUp, state & NDSDirectionalControlDirectionDown, state & NDSDirectionalControlDirectionLeft, state & NDSDirectionalControlDirectionRight);
}

- (IBAction)pressedABXY:(NDSButtonControl *)sender
{
    NDSButtonControlButton state = sender.selectedButtons;
    EMU_setABXY(state & NDSButtonControlButtonA, state & NDSButtonControlButtonB, state & NDSButtonControlButtonX, state & NDSButtonControlButtonY);
}

- (IBAction)onButtonUp:(UIControl*)sender
{
    EMU_buttonUp((BUTTON_ID)sender.tag);
}

- (IBAction)onButtonDown:(UIControl*)sender
{
    EMU_buttonDown((BUTTON_ID)sender.tag);
}

- (void)touchScreenAtPoint:(CGPoint)point
{
    if (point.y < self.glkView.bounds.size.height/2) return;
    
    CGAffineTransform t = CGAffineTransformConcat(CGAffineTransformMakeTranslation(0, -self.glkView.bounds.size.height/2), CGAffineTransformMakeScale(256/self.glkView.bounds.size.width, 192/(self.glkView.bounds.size.height/2)));
    point = CGPointApplyAffineTransform(point, t);
    
    EMU_touchScreenTouch(point.x, point.y);
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    [self touchScreenAtPoint:[[touches anyObject] locationInView:self.glkView]];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    [self touchScreenAtPoint:[[touches anyObject] locationInView:self.glkView]];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    EMU_touchScreenRelease();
}

- (IBAction)hideEmulator:(id)sender
{
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:@"Background or Kill?\nBackgrounding keeps the current game alive for later, whereas killing it will completely close it." delegate:self cancelButtonTitle:@"Cancel" destructiveButtonTitle:@"Kill" otherButtonTitles:@"Background", nil];
    [sheet showInView:self.view];
    
}

#pragma mark UIActionSheet delegate
- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == 0)
    {
        EMU_closeRom();
        [AppDelegate sharedInstance].gameOpen = NO;
        [self dismissViewControllerAnimated:YES completion:nil];
    } else if (buttonIndex == 1) {
        [self pauseEmulation];
        [self dismissModalViewControllerAnimated:YES];
    }
    
}

@end
