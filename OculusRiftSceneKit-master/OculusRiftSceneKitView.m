#import "OculusRiftSceneKitView.h"
#import "OculusRiftDevice.h"

#define STRINGIZE(x) #x
#define STRINGIZE2(x) STRINGIZE(x)
#define SHADER_STRING(text) @ STRINGIZE2(text)

#define EYE_RENDER_RESOLUTION_X 800
#define EYE_RENDER_RESOLUTION_Y 1000

NSString *const kOCVRVertexShaderString = SHADER_STRING
(
 attribute vec4 position;
 attribute vec4 inputTextureCoordinate;
 
 varying vec2 textureCoordinate;
 
 void main()
 {
     gl_Position = position;
     textureCoordinate = inputTextureCoordinate.xy;
 }
);

NSString *const kOCVRPassthroughFragmentShaderString = SHADER_STRING
(
 varying vec2 textureCoordinate;
 
 uniform sampler2D inputImageTexture;
 
 void main()
 {
//     gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0);
     gl_FragColor = texture2D(inputImageTexture, textureCoordinate);
 }
);


// Lens correction shader drawn from the Oculus VR SDK
NSString *const kOCVRLensCorrectionFragmentShaderString = SHADER_STRING
(
 varying vec2 textureCoordinate;
 
 uniform sampler2D inputImageTexture;
 
 uniform vec2 LensCenter;
 uniform vec2 ScreenCenter;
 uniform vec2 Scale;
 uniform vec2 ScaleIn;
 uniform vec4 HmdWarpParam;
 
 vec2 HmdWarp(vec2 in01)
 {
     vec2 theta = (in01 - LensCenter) * ScaleIn; // Scales to [-1, 1]
     float rSq = theta.x * theta.x + theta.y * theta.y;
     vec2  theta1 = theta * (HmdWarpParam.x + HmdWarpParam.y * rSq + HmdWarpParam.z * rSq * rSq + HmdWarpParam.w * rSq * rSq * rSq);
//     return LensCenter + Scale * theta1;
     return ScreenCenter + Scale * theta1;
 }
 void main()
 {
     vec2 tc = HmdWarp(textureCoordinate);
     if (!all(equal(clamp(tc, ScreenCenter-vec2(0.5,0.5), ScreenCenter+vec2(0.5,0.5)), tc)))
         gl_FragColor = vec4(0);
     else
         gl_FragColor = texture2D(inputImageTexture, tc);
 }
 
);

@interface OculusRiftSceneKitView()
{
    SCNRenderer *leftEyeRenderer, *rightEyeRenderer;
 
    GLProgram *displayProgram;
    GLint displayPositionAttribute, displayTextureCoordinateAttribute;
    GLint displayInputTextureUniform;
    
    GLint lensCenterUniform, screenCenterUniform, scaleUniform, scaleInUniform, hmdWarpParamUniform;
    
    GLuint leftEyeTexture, rightEyeTexture;
    GLuint leftEyeDepthTexture, rightEyeDepthTexture;
    GLuint leftEyeFramebuffer, rightEyeFramebuffer;
    GLuint leftEyeDepthBuffer, rightEyeDepthBuffer;
    
    CVDisplayLinkRef displayLink;

    BOOL leftSceneReady, rightSceneReady;
    
    SCNNode *leftEyeCameraNode, *rightEyeCameraNode;
    SCNNode *headRotationNode, *headPositionNode;
    
    CGFloat redBackgroundComponent, blueBackgroundComponent, greenBackgroundComponent, alphaBackgroundComponent;
    
    OculusRiftDevice *oculusRiftDevice;
}

- (void)commonInit;
- (void)configureEyeRenderingFramebuffers;
- (void)configureDisplayProgram;
- (void)renderStereoscopicScene;

@end

static CVReturn renderCallback(CVDisplayLinkRef displayLink,
							   const CVTimeStamp *inNow,
							   const CVTimeStamp *inOutputTime,
							   CVOptionFlags flagsIn,
							   CVOptionFlags *flagsOut,
							   void *displayLinkContext)
{
    return [(__bridge OculusRiftSceneKitView *)displayLinkContext renderTime:inOutputTime];
}

@implementation OculusRiftSceneKitView

@synthesize scene = _scene;
@synthesize interpupillaryDistance = _interpupillaryDistance;
@synthesize headLocation = _headLocation;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithFrame:(CGRect)frame
{
    if (!(self = [super initWithFrame:frame]))
    {
		return nil;
    }
    
    [self commonInit];
    
    return self;
}

-(id)initWithCoder:(NSCoder *)coder
{
	if (!(self = [super initWithCoder:coder]))
    {
        return nil;
	}
    
    [self commonInit];
    
	return self;
}

- (void)commonInit;
{
    NSOpenGLPixelFormatAttribute pixelFormatAttributes[] = {
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersionLegacy,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFANoRecovery,
        NSOpenGLPFAAccelerated,
        NSOpenGLPFADepthSize, 24,
        0
    };
    
    NSOpenGLPixelFormat *pixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:pixelFormatAttributes];
	if (pixelFormat == nil)
	{
		NSLog(@"Error: No appropriate pixel format found");
	}
    
    // TODO: Take into account the sharegroup
    NSOpenGLContext *context = [[NSOpenGLContext alloc] initWithFormat:pixelFormat shareContext:nil];
    
    NSAssert(context != nil, @"Unable to create an OpenGL context. The GPUImage framework requires OpenGL support to work.");
    [self setOpenGLContext:context];
    
    GLint swap = 0;
    [[self openGLContext] setValues:&swap forParameter:NSOpenGLCPSwapInterval];
    
    [self configureEyeRenderingFramebuffers];
    [self configureDisplayProgram];
    
    oculusRiftDevice = [[OculusRiftDevice alloc] init];
    
    leftEyeRenderer = [SCNRenderer rendererWithContext:[context CGLContextObj] options:nil];
    leftEyeRenderer.delegate = self;
    rightEyeRenderer = [SCNRenderer rendererWithContext:[context CGLContextObj] options:nil];
    rightEyeRenderer.delegate = self;
    
    _interpupillaryDistance = 64.0;
    _headLocation = SCNVector3Make(0.0, 0.0, 200.0);
    
    redBackgroundComponent = 0.0;
    greenBackgroundComponent = 0.0;
    blueBackgroundComponent = 1.0;
    alphaBackgroundComponent = 1.0;
    
    CGDirectDisplayID   displayID = CGMainDisplayID();
    CVReturn            error = kCVReturnSuccess;
    error = CVDisplayLinkCreateWithCGDisplay(displayID, &displayLink);
    if (error)
    {
        NSLog(@"DisplayLink created with error:%d", error);
        displayLink = NULL;
    }
    CVDisplayLinkSetOutputCallback(displayLink, renderCallback, (__bridge void *)self);
}

- (void)dealloc;
{
    glDeleteFramebuffers(1, &leftEyeFramebuffer);
    glDeleteRenderbuffers(1, &leftEyeDepthBuffer);
    glDeleteTextures(1, &leftEyeTexture);
    glDeleteFramebuffers(1, &rightEyeFramebuffer);
    glDeleteRenderbuffers(1, &rightEyeDepthBuffer);
    glDeleteTextures(1, &rightEyeTexture);
    CVDisplayLinkStop(displayLink);
    CVDisplayLinkRelease(displayLink);
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (void)keyDown:(NSEvent *)theEvent
{
    NSString *string = theEvent.characters;
    NSLog(@"Key press: %@", string);
}

- (void)configureEyeRenderingFramebuffers;
{
    [self.openGLContext makeCurrentContext];

    glActiveTexture(GL_TEXTURE0);
    // Left eye framebuffer
    glGenTextures(1, &leftEyeTexture);
    glBindTexture(GL_TEXTURE_2D, leftEyeTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    glGenFramebuffers(1, &leftEyeFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, leftEyeFramebuffer);
    
    glGenRenderbuffers(1, &leftEyeDepthBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, leftEyeDepthBuffer);

    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, EYE_RENDER_RESOLUTION_X, EYE_RENDER_RESOLUTION_Y);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, leftEyeDepthBuffer);

    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, EYE_RENDER_RESOLUTION_X, EYE_RENDER_RESOLUTION_Y, 0, GL_BGRA, GL_UNSIGNED_BYTE, 0);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, leftEyeTexture, 0);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    NSAssert(status == GL_FRAMEBUFFER_COMPLETE, @"Incomplete left eye FBO: %d", status);
    glBindTexture(GL_TEXTURE_2D, 0);

    // Right eye framebuffer
    glGenTextures(1, &rightEyeTexture);
    glBindTexture(GL_TEXTURE_2D, rightEyeTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    glGenFramebuffers(1, &rightEyeFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, rightEyeFramebuffer);
    
    glGenRenderbuffers(1, &rightEyeDepthBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, rightEyeDepthBuffer);

    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, EYE_RENDER_RESOLUTION_X, EYE_RENDER_RESOLUTION_Y);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, rightEyeDepthBuffer);

    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, EYE_RENDER_RESOLUTION_X, EYE_RENDER_RESOLUTION_Y, 0, GL_BGRA, GL_UNSIGNED_BYTE, 0);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rightEyeTexture, 0);
    status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    NSAssert(status == GL_FRAMEBUFFER_COMPLETE, @"Incomplete right eye FBO: %d", status);
    glBindTexture(GL_TEXTURE_2D, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
}

- (void)configureDisplayProgram;
{
    [self.openGLContext makeCurrentContext];

//    displayProgram = [[GLProgram alloc] initWithVertexShaderString:kOCVRLensCorrectionVertexShaderString fragmentShaderString:kOCVRLensCorrectionFragmentShaderString];
    displayProgram = [[GLProgram alloc] initWithVertexShaderString:kOCVRVertexShaderString fragmentShaderString:kOCVRLensCorrectionFragmentShaderString];
//    displayProgram = [[GLProgram alloc] initWithVertexShaderString:kOCVRVertexShaderString fragmentShaderString:kOCVRPassthroughFragmentShaderString];
    [displayProgram addAttribute:@"position"];
    [displayProgram addAttribute:@"inputTextureCoordinate"];
    
    if (![displayProgram link])
    {
        NSString *progLog = [displayProgram programLog];
        NSLog(@"Program link log: %@", progLog);
        NSString *fragLog = [displayProgram fragmentShaderLog];
        NSLog(@"Fragment shader compile log: %@", fragLog);
        NSString *vertLog = [displayProgram vertexShaderLog];
        NSLog(@"Vertex shader compile log: %@", vertLog);
        displayProgram = nil;
        NSAssert(NO, @"Filter shader link failed");
    }
    
    displayPositionAttribute = [displayProgram attributeIndex:@"position"];
    displayTextureCoordinateAttribute = [displayProgram attributeIndex:@"inputTextureCoordinate"];
    displayInputTextureUniform = [displayProgram uniformIndex:@"inputImageTexture"];

    screenCenterUniform = [displayProgram uniformIndex:@"ScreenCenter"];
    scaleUniform = [displayProgram uniformIndex:@"Scale"];
    scaleInUniform = [displayProgram uniformIndex:@"ScaleIn"];
    hmdWarpParamUniform = [displayProgram uniformIndex:@"HmdWarpParam"];
    lensCenterUniform = [displayProgram uniformIndex:@"LensCenter"];

    [displayProgram use];
    
    glEnableVertexAttribArray(displayPositionAttribute);
    glEnableVertexAttribArray(displayTextureCoordinateAttribute);
}

- (void)renderStereoscopicScene;
{
    static const GLfloat leftEyeVertices[] = {
        -1.0f, -1.0f,
        0.0f, -1.0f,
        -1.0f,  1.0f,
        0.0f,  1.0f,
    };

    static const GLfloat rightEyeVertices[] = {
        0.0f, -1.0f,
        1.0f, -1.0f,
        0.0f,  1.0f,
        1.0f,  1.0f,
    };

    static const GLfloat textureCoordinates[] = {
        0.0f, 0.0f,
        1.0f, 0.0f,
        0.0f, 1.0f,
        1.0f, 1.0f,
    };

    [self.openGLContext makeCurrentContext];
    [displayProgram use];
    
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glBindRenderbuffer(GL_RENDERBUFFER, 0);    
    glViewport(0, 0, (GLint)self.bounds.size.width, (GLint)self.bounds.size.height);

    glClearColor(redBackgroundComponent, greenBackgroundComponent, blueBackgroundComponent, alphaBackgroundComponent);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
    
    glEnableVertexAttribArray(displayPositionAttribute);
    glEnableVertexAttribArray(displayTextureCoordinateAttribute);
    
    [self lockFocus];

    // Left eye
    float w = 1.0;
    float h = 1.0;
    float x = 0.0;
    float y = 0.0;
//    float distortion = 0.151976;
    float distortion = 0.151976 * 2.0;
    float scaleFactor = 0.583225;
//    float scaleFactor = 1.0;
//    float scaleFactor = 0.4;
    float as = 640.0 / 800.0;
    glUniform2f(scaleUniform, (w/2) * scaleFactor, (h/2) * scaleFactor * as);
    glUniform2f(scaleInUniform, (2/w), (2/h) / as);
    glUniform4f(hmdWarpParamUniform, 1.0, 0.22, 0.24, 0.0);
    glUniform2f(lensCenterUniform, x + (w + distortion * 0.5f)*0.5f, y + h*0.5f);
    glUniform2f(screenCenterUniform, x + w*0.5f, y + h*0.5f);
//    glUniform2f(screenCenterUniform, 0.5f, 0.5f);
    
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, leftEyeTexture);
    glUniform1i(displayInputTextureUniform, 0);
    glVertexAttribPointer(displayPositionAttribute, 2, GL_FLOAT, 0, 0, leftEyeVertices);
    glVertexAttribPointer(displayTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, textureCoordinates);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindTexture(GL_TEXTURE_2D, 0);


    
    // Right eye
//    w = 0.5;
//    h = 1.0;
//    x = 0.5;
//    y = 0.0;
    distortion = -0.151976 * 2.0;
    glUniform2f(lensCenterUniform, x + (w + distortion * 0.5f)*0.5f, y + h*0.5f);
    glUniform2f(screenCenterUniform, 0.5f, 0.5f);

    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, rightEyeTexture);
    glUniform1i(displayInputTextureUniform, 1);
    glVertexAttribPointer(displayPositionAttribute, 2, GL_FLOAT, 0, 0, rightEyeVertices);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindTexture(GL_TEXTURE_2D, 0);

//    [self.openGLContext flushBuffer];
//    [self.openGLContext flushBuffer];
    [self unlockFocus];

    glDisableVertexAttribArray(displayPositionAttribute);
    glDisableVertexAttribArray(displayTextureCoordinateAttribute);

    rightSceneReady = NO;
    leftSceneReady = NO;
}

- (void)reshape;
{
    [leftEyeRenderer render];
    [rightEyeRenderer render];

    [self renderStereoscopicScene];
}

- (CVReturn)renderTime:(const CVTimeStamp *)timeStamp;
{
    // TODO: Run this on a background queue to avoid blocking the main thread
    dispatch_sync(dispatch_get_main_queue(), ^{
        
        headRotationNode.transform = [oculusRiftDevice currentHeadTransform];
        
        [leftEyeRenderer render];
        [rightEyeRenderer render];
        [self renderStereoscopicScene];
        [self.openGLContext flushBuffer];
    });

    CVReturn rv = kCVReturnSuccess;
    return rv;
}

#pragma mark -
#pragma mark SCNSceneRendererDelegate methods

- (void)renderer:(id <SCNSceneRenderer>)aRenderer willRenderScene:(SCNScene *)scene atTime:(NSTimeInterval)time;
{
    [self.openGLContext makeCurrentContext];


    
    if (aRenderer == leftEyeRenderer)
    {
        glBindFramebuffer(GL_FRAMEBUFFER, leftEyeFramebuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, leftEyeDepthBuffer);

        glViewport(0, 0, EYE_RENDER_RESOLUTION_X, EYE_RENDER_RESOLUTION_Y);
    }
    else if (aRenderer == rightEyeRenderer)
    {
        glBindFramebuffer(GL_FRAMEBUFFER, rightEyeFramebuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, rightEyeDepthBuffer);
        
        glViewport(0, 0, EYE_RENDER_RESOLUTION_X, EYE_RENDER_RESOLUTION_Y);
    }
    
    glClearColor(redBackgroundComponent, greenBackgroundComponent, blueBackgroundComponent, alphaBackgroundComponent);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
}

- (void)renderer:(id <SCNSceneRenderer>)aRenderer didRenderScene:(SCNScene *)scene atTime:(NSTimeInterval)time;
{
    [self.openGLContext makeCurrentContext];
    

    
    if (aRenderer == leftEyeRenderer)
    {
        if (rightSceneReady)
        {
            [self renderStereoscopicScene];
        }
        else
        {
            leftSceneReady = YES;
        }
    }
    else if (aRenderer == rightEyeRenderer)
    {
        if (leftSceneReady)
        {
            [self renderStereoscopicScene];
        }
        else
        {
            rightSceneReady = YES;
        }        
    }
}

#pragma mark -
#pragma mark Accessors

- (void)setBackgroundColorRed:(CGFloat)redComponent green:(CGFloat)greenComponent blue:(CGFloat)blueComponent alpha:(CGFloat)alphaComponent;
{
    redBackgroundComponent = redComponent;
    blueBackgroundComponent = blueComponent;
    greenBackgroundComponent = greenComponent;
    alphaBackgroundComponent = alphaComponent;
}

- (void)setScene:(SCNScene *)newValue;
{
    CVDisplayLinkStop(displayLink);

    NSLog(@"Setting scene");
    
    leftSceneReady = NO;
    rightSceneReady = NO;
    
    glUniform4f(hmdWarpParamUniform, 1.0, 0.22, 0.24, 0.0);

    
//    CGFloat distortionCorrection = 1.0 + 0.22 + 0.24;
//    CGFloat verticalFOV = 2.0 * atan(distortionCorrection * 0.09356 / (2.0 * 0.041)) * 180.0 / M_PI;// VScreenSize = 0.09356, EyeToScreenDistance = 0.041
//    CGFloat horizontalFOV = 2.0 * atan(distortionCorrection * 0.14976 / (2.0 * 0.041)) * 180.0 / M_PI;// HScreenSize = 0.14976, EyeToScreenDistance = 0.041
    CGFloat verticalFOV = 97.5;
    CGFloat horizontalFOV = 80.8;
    
    NSLog(@"Vertical FOV: %f", verticalFOV);
    NSLog(@"Horizontal FOV: %f", horizontalFOV);
    
    _scene = newValue;
    leftEyeRenderer.scene = _scene;
    rightEyeRenderer.scene = _scene;

    headRotationNode = [SCNNode node];
    headPositionNode = [SCNNode node];
    headPositionNode.position = _headLocation;
    [_scene.rootNode addChildNode:headPositionNode];
    [headPositionNode addChildNode:headRotationNode];

    // TODO: Deal with re-adding camera nodes for setting the same scene
    // 64 mm interpupillary distance
    SCNCamera *leftEyeCamera = [SCNCamera camera];
    leftEyeCamera.xFov = 120;
    leftEyeCamera.yFov = verticalFOV;
    leftEyeCamera.zNear = horizontalFOV;
    leftEyeCamera.zFar = 2000;
	leftEyeCameraNode = [SCNNode node];
	leftEyeCameraNode.camera = leftEyeCamera;
    leftEyeCameraNode.transform = CATransform3DMakeTranslation(-(_interpupillaryDistance / 2.0), 0.0, 0.0);
    [headRotationNode addChildNode:leftEyeCameraNode];
    
    SCNCamera *rightEyeCamera = [SCNCamera camera];
    rightEyeCamera.xFov = 120;
    rightEyeCamera.yFov = verticalFOV;
    rightEyeCamera.zNear = horizontalFOV;
    rightEyeCamera.zFar = 2000;
	rightEyeCameraNode = [SCNNode node];
	rightEyeCameraNode.camera = rightEyeCamera;
    rightEyeCameraNode.transform = CATransform3DMakeTranslation((_interpupillaryDistance / 2.0), 0.0, 0.0);
    [headRotationNode addChildNode:rightEyeCameraNode];
    
    // Tell each view which camera in the scene to use
    leftEyeRenderer.pointOfView = leftEyeCameraNode;
    rightEyeRenderer.pointOfView = rightEyeCameraNode;
    
    [leftEyeRenderer render];
    [rightEyeRenderer render];
    
    CVDisplayLinkStart(displayLink);
}

- (void)setInterpupillaryDistance:(CGFloat)newValue;
{
    NSLog(@"Ipd: %f", newValue);
    
    _interpupillaryDistance = newValue;
    leftEyeCameraNode.transform = CATransform3DMakeTranslation(-(_interpupillaryDistance / 2.0), 0.0, 0.0);
    rightEyeCameraNode.transform = CATransform3DMakeTranslation((_interpupillaryDistance / 2.0), 0.0, 0.0);
}

- (void)setHeadLocation:(SCNVector3)newValue;
{
    _headLocation = newValue;
    headPositionNode.position = newValue;
}

@end
