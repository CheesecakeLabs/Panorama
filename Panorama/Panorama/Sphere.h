//
//  Sphere.h
//  Panorama
//
//  Created by Marcelo Salloum dos Santos on 16/12/16.
//  Copyright © 2016 Robby Kraft. All rights reserved.
//
#import <Foundation/Foundation.h>
#import <GLKit/GLKit.h>

@interface Sphere : NSObject

-(bool) execute;
-(id) init:(GLint)stacks slices:(GLint)slices radius:(GLfloat)radius textureFile:(NSString *)textureFile;
-(void) swapTexture:(NSString*)textureFile;
-(void) swapTextureWithImage:(UIImage*)image;
-(CGSize) getTextureSize;

@end
