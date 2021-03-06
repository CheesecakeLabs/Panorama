//
//  PanoramaView.m
//  Panorama
//
//  Created by Robby Kraft on 8/24/13.
//  Copyright (c) 2013 Robby Kraft. All rights reserved.
//

#import <CoreMotion/CoreMotion.h>
#import <OpenGLES/ES1/gl.h>
#import "PanoramaView.h"
#import "Sphere.h"

#define FPS 60
#define FOV_MIN 1
#define FOV_MAX 155
#define Z_NEAR 0.1f
#define Z_FAR 100.0f

// this appears to be the best way to grab orientation. if this becomes formalized, just make sure the orientations match
#define SENSOR_ORIENTATION [[UIApplication sharedApplication] statusBarOrientation] //enum  1(NORTH)  2(SOUTH)  3(EAST)  4(WEST)

// this really should be included in GLKit
GLKQuaternion GLKQuaternionFromTwoVectors(GLKVector3 u, GLKVector3 v){
    GLKVector3 w = GLKVector3CrossProduct(u, v);
    GLKQuaternion q = GLKQuaternionMake(w.x, w.y, w.z, GLKVector3DotProduct(u, v));
    q.w += GLKQuaternionLength(q);
    return GLKQuaternionNormalize(q);
}

@interface PanoramaView (){
    Sphere *sphere, *meridians;
    CMMotionManager *motionManager;
    UIPinchGestureRecognizer *pinchGesture;
    UIPanGestureRecognizer *panGesture;
    GLKMatrix4 _projectionMatrix, _attitudeMatrix, _offsetMatrix;
    float _aspectRatio;
    GLfloat circlePoints[64*3];  // meridian lines
    NSMutableArray *buttonsArray;
}
@end

@implementation PanoramaView


#pragma mark - Initialization

-(id) init{
    return [self initWithFrame:[[UIScreen mainScreen] bounds]];
}


- (id)initWithCoder:(NSCoder *)decoder
{
    self = [super initWithCoder:decoder];
    if (self) {
        EAGLContext *context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
        [EAGLContext setCurrentContext:context];
        self.context = context;
        [self initDevice];
        [self initOpenGL:context];
        sphere = [[Sphere alloc] init:48 slices:48 radius:10.0 textureFile:nil];
        meridians = [[Sphere alloc] init:48 slices:48 radius:8.0 textureFile:@"equirectangular-projection-lines.png"];
        buttonsArray = [[NSMutableArray alloc] init];
    }
    return self;
}


- (id)initWithFrame:(CGRect)frame{
    EAGLContext *context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
    [EAGLContext setCurrentContext:context];
    self.context = context;
    return [self initWithFrame:frame context:context];
}


-(id) initWithFrame:(CGRect)frame context:(EAGLContext *)context{
    self = [super initWithFrame:frame];
    if (self) {
        [self initDevice];
        [self initOpenGL:context];
        sphere = [[Sphere alloc] init:48 slices:48 radius:10.0 textureFile:nil];
        meridians = [[Sphere alloc] init:48 slices:48 radius:8.0 textureFile:@"equirectangular-projection-lines.png"];
        buttonsArray = [[NSMutableArray alloc] init];
    }
    return self;
}


-(void) didMoveToSuperview{
    // this breaks MVC, but useful for setting GLKViewController's frame rate
    UIResponder *responder = self;
    while (![responder isKindOfClass:[GLKViewController class]]) {
        responder = [responder nextResponder];
        if (responder == nil){
            break;
        }
    }
    if([responder respondsToSelector:@selector(setPreferredFramesPerSecond:)])
        [(GLKViewController*)responder setPreferredFramesPerSecond:FPS];
}


-(void) initDevice{
    motionManager = [[CMMotionManager alloc] init];
    pinchGesture = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinchHandler:)];
    [pinchGesture setEnabled:NO];
    [self addGestureRecognizer:pinchGesture];
    panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panHandler:)];
    [panGesture setMaximumNumberOfTouches:1];
    [panGesture setEnabled:NO];
    [self addGestureRecognizer:panGesture];
}


#pragma mark - Configuration

- (void)updateAspectRatio {
    _aspectRatio = self.frame.size.width/self.frame.size.height;
    float newFieldOfView = 45 + 45 * atanf(_aspectRatio);
    [self setFieldOfView:newFieldOfView];
}


-(void)setFieldOfView:(float)fieldOfView{
    _fieldOfView = fieldOfView;
    [self rebuildProjectionMatrix];
}


-(void) setImageWithName:(NSString*)fileName{
    [sphere swapTexture:fileName];
}


-(void) setImage:(UIImage *)image {
    [sphere swapTextureWithImage:image];
}


-(void) setTouchToPan:(BOOL)touchToPan{
    _touchToPan = touchToPan;
    [panGesture setEnabled:_touchToPan];
}


-(void) setPinchToZoom:(BOOL)pinchToZoom{
    _pinchToZoom = pinchToZoom;
    [pinchGesture setEnabled:_pinchToZoom];
}


-(void) setOrientToDevice:(BOOL)orientToDevice{
    _orientToDevice = orientToDevice;
    if(motionManager.isDeviceMotionAvailable){
        if(_orientToDevice)
            [motionManager startDeviceMotionUpdates];
        else
            [motionManager stopDeviceMotionUpdates];
    }
}


-(void) setVRMode:(BOOL)VRMode{
    _VRMode = VRMode;
    if(_VRMode){
        _aspectRatio = self.frame.size.width/(self.frame.size.height*0.5);
        [self rebuildProjectionMatrix];
    } else{
        _aspectRatio = self.frame.size.width/self.frame.size.height;
        [self rebuildProjectionMatrix];
    }
}


#pragma mark- OpenGL Calculations

-(void)initOpenGL:(EAGLContext*)context{
    [(CAEAGLLayer*)self.layer setOpaque:NO];
    _aspectRatio = self.frame.size.width/self.frame.size.height;
    _fieldOfView = 45 + 45 * atanf(_aspectRatio); // hell ya
    [self rebuildProjectionMatrix];
    _attitudeMatrix = GLKMatrix4Identity;
    _offsetMatrix = GLKMatrix4Identity;
    [self customGL];
    [self makeLatitudeLines];
}


-(void)rebuildProjectionMatrix{
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    GLfloat frustum = Z_NEAR * tanf(_fieldOfView*0.00872664625997);  // pi/180/2
    _projectionMatrix = GLKMatrix4MakeFrustum(-frustum, frustum, -frustum/_aspectRatio, frustum/_aspectRatio, Z_NEAR, Z_FAR);
    glMultMatrixf(_projectionMatrix.m);
    if(!_VRMode){
        glViewport(0, 0, self.frame.size.width, self.frame.size.height);
    } else{
        // no matter. glViewport gets called every draw call anyway.
    }
    glMatrixMode(GL_MODELVIEW);
}


-(void) customGL{
    glMatrixMode(GL_MODELVIEW);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
}


-(void)draw{
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    if(_VRMode) {
        float scale = [UIScreen mainScreen].scale;
        // one eye
        glMatrixMode(GL_PROJECTION);
        glViewport(0, 0, self.frame.size.width * scale, self.frame.size.height * scale * 0.5);
        glMatrixMode(GL_MODELVIEW);
        [self renderScene];
        // other eye
        glMatrixMode(GL_PROJECTION);
        glViewport(0, self.frame.size.height * scale * 0.5, self.frame.size.width * scale, self.frame.size.height * scale* 0.5);
        glMatrixMode(GL_MODELVIEW);
        [self renderScene];
    }else{
        [self renderScene];
    }
}


-(void) renderScene{
    static GLfloat whiteColor[] = {1.0f, 1.0f, 1.0f, 1.0f};
    static GLfloat clearColor[] = {0.0f, 0.0f, 0.0f, 0.0f};
    glPushMatrix(); // begin device orientation
    _attitudeMatrix = GLKMatrix4Multiply([self getDeviceOrientationMatrix], _offsetMatrix);
    
    [self updateButtonsLocation];
    glMultMatrixf(_attitudeMatrix.m);
    glMaterialfv(GL_FRONT_AND_BACK, GL_EMISSION, whiteColor);  // panorama at full color
    [sphere execute];
    glMaterialfv(GL_FRONT_AND_BACK, GL_EMISSION, clearColor);
    
    // touch lines
    if(_showTouches && _numberOfTouches){
        glColor4f(1.0f, 1.0f, 1.0f, 0.5f);
        for(int i = 0; i < [[_touches allObjects] count]; i++){
            glPushMatrix();
            CGPoint touchPoint = CGPointMake([(UITouch*)[[_touches allObjects] objectAtIndex:i] locationInView:self].x, [(UITouch*)[[_touches allObjects] objectAtIndex:i] locationInView:self].y);
            if(_VRMode){
                touchPoint.y = ( (int)touchPoint.y % (int)(self.frame.size.height * 0.5) ) * 2.0;
            }
            [self drawHotspotLines:[self vectorFromScreenLocation:touchPoint inAttitude:_attitudeMatrix]];
            glPopMatrix();
        }
        glColor4f(1.0f, 1.0f, 1.0f, 1.0f);
    }
    glPopMatrix(); // end device orientation
}


#pragma mark - Trigonometric Calculations

-(GLKMatrix4) getDeviceOrientationMatrix{
    if(_orientToDevice && [motionManager isDeviceMotionActive]){
        CMRotationMatrix a = [[[motionManager deviceMotion] attitude] rotationMatrix];
        // arrangements of mappings of sensor axis to virtual axis (columns)
        // and combinations of 90 degree rotations (rows)
        switch (SENSOR_ORIENTATION) {
            case 4:
                return GLKMatrix4Make( a.m21,-a.m11, a.m31, 0.0f,
                                      a.m23,-a.m13, a.m33, 0.0f,
                                      -a.m22, a.m12,-a.m32, 0.0f,
                                      0.0f , 0.0f , 0.0f , 1.0f);
            case 3:
                return GLKMatrix4Make(-a.m21, a.m11, a.m31, 0.0f,
                                      -a.m23, a.m13, a.m33, 0.0f,
                                      a.m22,-a.m12,-a.m32, 0.0f,
                                      0.0f , 0.0f , 0.0f , 1.0f);
            case 2:
                return GLKMatrix4Make(-a.m11,-a.m21, a.m31, 0.0f,
                                      -a.m13,-a.m23, a.m33, 0.0f,
                                      a.m12, a.m22,-a.m32, 0.0f,
                                      0.0f , 0.0f , 0.0f , 1.0f);
            case 1:
            default:
                return GLKMatrix4Make( a.m11, a.m21, a.m31, 0.0f,
                                      a.m13, a.m23, a.m33, 0.0f,
                                      -a.m12,-a.m22,-a.m32, 0.0f,
                                      0.0f , 0.0f , 0.0f , 1.0f);
        }
    }
    return GLKMatrix4Identity;
}


-(void) orientToVector:(GLKVector3)v{
    //    GLKVector3 currentVector = [self vectorFromScreenLocation:CGPointMake([UIScreen mainScreen].bounds.size.width/2, [UIScreen mainScreen].bounds.size.height/2) inAttitude:_attitudeMatrix];
    //    currentVector.y = 0;
    //
    //    GLKVector3 newVector = GLKVector3Make(currentVector.x + v.x, 0, currentVector.z + v.z);
    //
    //    GLKQuaternion q = GLKQuaternionFromTwoVectors(currentVector, newVector);
    _offsetMatrix = GLKMatrix4Identity;
    
}


-(void) orientToAzimuth:(float)azimuth Altitude:(float)altitude{
    [self orientToVector:GLKVector3Make(-cosf(azimuth), sinf(altitude), sinf(azimuth))];
}


-(CGPoint) imagePixelAtScreenLocation:(CGPoint)point{
    return [self imagePixelFromVector:[self vectorFromScreenLocation:point inAttitude:_attitudeMatrix]];
}


-(CGPoint) imagePixelFromVector:(GLKVector3)vector{
    CGPoint pxl = CGPointMake((atan2f(-vector.x, vector.z))/(2*M_PI), acosf(vector.y)/M_PI);
    if(pxl.x < 0.0) pxl.x += 1.0;
    CGSize tex = [sphere getTextureSize];
    if(!(tex.width == 0.0f && tex.height == 0.0f)){
        pxl.x *= tex.width;
        pxl.y *= tex.height;
    }
    return pxl;
}


-(GLKVector3) vectorFromScreenLocation:(CGPoint)point{
    return [self vectorFromScreenLocation:point inAttitude:_attitudeMatrix];
}


-(GLKVector3) vectorFromScreenLocation:(CGPoint)point inAttitude:(GLKMatrix4)matrix{
    GLKMatrix4 inverse = GLKMatrix4Invert(GLKMatrix4Multiply(_projectionMatrix, matrix), nil);
    GLKVector4 screen = GLKVector4Make(2.0*(point.x/self.frame.size.width-.5),
                                       2.0*(.5-point.y/self.frame.size.height),
                                       1.0, 1.0);
    GLKVector4 vec = GLKMatrix4MultiplyVector4(inverse, screen);
    return GLKVector3Normalize(GLKVector3Make(vec.x, vec.y, vec.z));
}


-(CGPoint) screenLocationFromVector:(GLKVector3)vector{
    return [self screenLocationFromVector:vector positiveOnly:NO];
}


-(CGPoint) screenLocationFromVector:(GLKVector3)vector positiveOnly:(BOOL)positiveOnly {
    GLKMatrix4 matrix = GLKMatrix4Multiply(_projectionMatrix, _attitudeMatrix);
    GLKVector3 screenVector = GLKMatrix4MultiplyVector3(matrix, vector);
    if (!positiveOnly || screenVector.z < 0) {
        return CGPointMake( (screenVector.x/screenVector.z/2.0 + 0.5) * self.frame.size.width,
                           (0.5-screenVector.y/screenVector.z/2) * self.frame.size.height );
    }
    return CGPointZero;
}


-(BOOL) computeScreenLocation:(CGPoint*)location fromVector:(GLKVector3)vector inAttitude:(GLKMatrix4)matrix{
    GLKVector4 screenVector;
    GLKVector4 vector4;
    if(location == NULL)
        return NO;
    matrix = GLKMatrix4Multiply(_projectionMatrix, matrix);
    vector4 = GLKVector4Make(vector.x, vector.y, vector.z, 1);
    screenVector = GLKMatrix4MultiplyVector4(matrix, vector4);
    location->x = (screenVector.x/screenVector.w/2.0 + 0.5) * self.frame.size.width;
    location->y = (0.5-screenVector.y/screenVector.w/2) * self.frame.size.height;
    return (screenVector.z >= 0);
}


#pragma mark- TOUCHES

-(void) touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event{
    _touches = event.allTouches;
    _numberOfTouches = event.allTouches.count;
}


-(void) touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event{
    _touches = event.allTouches;
    _numberOfTouches = event.allTouches.count;
}


-(void) touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event{
    _touches = event.allTouches;
    _numberOfTouches = 0;
}


-(BOOL)touchInRect:(CGRect)rect{
    if(_numberOfTouches){
        bool found = false;
        for(int i = 0; i < [[_touches allObjects] count]; i++){
            CGPoint touchPoint = CGPointMake([(UITouch*)[[_touches allObjects] objectAtIndex:i] locationInView:self].x,
                                             [(UITouch*)[[_touches allObjects] objectAtIndex:i] locationInView:self].y);
            found |= CGRectContainsPoint(rect, [self imagePixelAtScreenLocation:touchPoint]);
        }
        return found;
    }
    return false;
}


-(void)pinchHandler:(UIPinchGestureRecognizer*)sender{
    _numberOfTouches = sender.numberOfTouches;
    static float zoom;
    if([sender state] == 1)
        zoom = _fieldOfView;
    if([sender state] == 2){
        CGFloat newFOV = zoom / [sender scale];
        if(newFOV < FOV_MIN) newFOV = FOV_MIN;
        else if(newFOV > FOV_MAX) newFOV = FOV_MAX;
        [self setFieldOfView:newFOV];
    }
    if([sender state] == 3){
        _numberOfTouches = 0;
    }
}


-(void) panHandler:(UIPanGestureRecognizer*)sender{
    static GLKVector3 touchVector;
    if([sender state] == 1){
        CGPoint location = [sender locationInView:sender.view];
        if (_lockPanToHorizon) {
            location.y = self.frame.size.height / 2.0;
        }
        if(_VRMode){
            location.y = ( (int)location.y % (int)(self.frame.size.height * 0.5) ) * 2.0;
        }
        touchVector = [self vectorFromScreenLocation:location inAttitude:_offsetMatrix];
    }
    else if([sender state] == 2){
        CGPoint location = [sender locationInView:sender.view];
        if (_lockPanToHorizon) {
            location.y = self.frame.size.height / 2.0;
        }
        if(_VRMode){
            location.y = ( (int)location.y % (int)(self.frame.size.height * 0.5) ) * 2.0;
        }
        GLKVector3 nowVector = [self vectorFromScreenLocation:location inAttitude:_offsetMatrix];
        GLKQuaternion q = GLKQuaternionFromTwoVectors(touchVector, nowVector);
        _offsetMatrix = GLKMatrix4Multiply(_offsetMatrix, GLKMatrix4MakeWithQuaternion(q));
    }
    else{
        _numberOfTouches = 0;
    }
}


#pragma mark - MERIDIANS?

-(void) makeLatitudeLines{
    for(int i = 0; i < 64; i++){
        circlePoints[i*3+0] = -sinf(M_PI*2/64.0f*i);
        circlePoints[i*3+1] = 0.0f;
        circlePoints[i*3+2] = cosf(M_PI*2/64.0f*i);
    }
}


-(void)drawHotspotLines:(GLKVector3)touchLocation{
    glLineWidth(2.0f);
    float scale = sqrtf(1-powf(touchLocation.y,2));
    glPushMatrix();
    glScalef(scale, 1.0f, scale);
    glTranslatef(0, touchLocation.y, 0);
    glDisableClientState(GL_NORMAL_ARRAY);
    glEnableClientState(GL_VERTEX_ARRAY);
    glVertexPointer(3, GL_FLOAT, 0, circlePoints);
    glDrawArrays(GL_LINE_LOOP, 0, 64);
    glDisableClientState(GL_VERTEX_ARRAY);
    glPopMatrix();
    
    glPushMatrix();
    glRotatef(-atan2f(-touchLocation.z, -touchLocation.x)*180/M_PI, 0, 1, 0);
    glRotatef(90, 1, 0, 0);
    glDisableClientState(GL_NORMAL_ARRAY);
    glEnableClientState(GL_VERTEX_ARRAY);
    glVertexPointer(3, GL_FLOAT, 0, circlePoints);
    glDrawArrays(GL_LINE_STRIP, 0, 33);
    glDisableClientState(GL_VERTEX_ARRAY);
    glPopMatrix();
}


-(void) dealloc{
    [EAGLContext setCurrentContext:nil];
}


#pragma mark - Scenario Buttons

- (void)addButton:(UIButton *)button toPositionVector:(GLKVector3)vector {
    NSDictionary *buttonDataDict = @{
                                     @"button": button,
                                     @"vector": @{
                                             @"x": @(vector.x),
                                             @"y": @(vector.y),
                                             @"z": @(vector.z)
                                             }
                                     };
    [buttonsArray addObject:buttonDataDict];
    [self addSubview:button];
}


- (void)removeAllButtons {
    for (NSDictionary *buttonDict in buttonsArray) {
        UIButton *button = buttonDict[@"button"];
        [button removeFromSuperview];
    }
    buttonsArray = [[NSMutableArray alloc] init];
}


- (void)addButton:(UIButton *)button toAngleDegrees:(float)degrees {
    GLKVector3 vector = [PanoramaView vector3FromAngleDegree:degrees];
    [self addButton:button toPositionVector:vector];
}


- (void)addButton:(UIButton *)button toAngleRadians:(float)radians {
    GLKVector3 vector = [PanoramaView vector3FromAngleRadian:radians];
    [self addButton:button toPositionVector:vector];
}


- (void)updateButtonsLocation {
    for (NSDictionary *buttonDataDict in buttonsArray) {
        // Gets Button
        UIButton *button = buttonDataDict[@"button"];
        
        // Gets Vector
        NSNumber *xObject = buttonDataDict[@"vector"][@"x"];
        NSNumber *yObject = buttonDataDict[@"vector"][@"y"];
        NSNumber *zObject = buttonDataDict[@"vector"][@"z"];
        GLKVector3 vector = GLKVector3Make(xObject.floatValue, yObject.floatValue, zObject.floatValue);
        
        // 2D Location
        CGPoint buttonLocation = [self screenLocationFromVector:vector positiveOnly:YES];
        
        if (!CGPointEqualToPoint(buttonLocation, CGPointZero)){
            [button setFrame:CGRectMake(buttonLocation.x, buttonLocation.y, 40, 40)];
        }
    }
}


+ (GLKVector3)vector3FromAngleDegree:(float)degrees {
    float radians = (degrees * M_PI) / 180;
    return [self vector3FromAngleRadian:radians];
}


+ (GLKVector3)vector3FromAngleRadian:(float)radian {
    float z = 0.1;
    float x = tan(radian) * z;
    if (fabsf(radian) > M_PI_2) {
        z = -z;
    }
    return GLKVector3Make(x, 0, z);
}


@end
