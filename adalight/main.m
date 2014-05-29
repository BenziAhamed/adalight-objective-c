//
//  main.m
//  adalight
//
//  Created by Benzi on 22/05/14.
//  Copyright (c) 2014 Benzi Ahamed. All rights reserved.
//
//  Use Freely.
//
//  This is a very simple implementation of adalight in Objective C.
//  It continuously grabs the content on the screen and outputs the
//  average pixel values to the basic 25 led strip connected to the arduino.
//  Refer the documentation from AdaFruit for Adalight and the github repo.
//  Based mostly from the colorswirl example for Serial port handling
//  and the Processing sample for LED color averaging.

#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <termios.h>
#include <time.h>
#include <math.h>

#define N_LEDS 25 // Max of 65536
#define N_LEDS_ACROSS 9.0f
#define N_LEDS_DOWN 6.0f

// Only used for bottom row leds
short maxBrightness = 150;

// Use to adjust the color temperature of the LEDS
// color_temperature should be the index of the color temperature to use
// from kelvin_table. Use 0 to disable this feature.
int color_temperature = 7;
int kelvin_table[][3] = {
    {255,255,255},  //0 - disable
    {255,56,0},     //1 - 1000K
    {255,109,0},    //2 - 1500K
    {255,137,18},   //3 - 2000K
    {255,161,72},   //4 - 2500K
    {255,180,107},  //5 - 3000K
    {255,196,137},  //6 - 3500K
    {255,209,163},  //7 - 4000K
    {255,219,186},  //8 - 4500K
    {255,228,206},  //9 - 5000K
    {255,236,224},  //10 - 5500K
    {255,243,239},  //11 - 6000K
    {255,249,253},  //12 - 6500K
    {245,243,255},  //13 - 7000K
    {235,238,255},  //14 - 7500K
    {227,233,255},  //15 - 8000K
    {220,229,255},  //16 - 8500K
    {214,225,255},  //17 - 9000K
    {208,222,255},  //18 - 9500K
    {204,219,255}   //19 - 10000K
};


// Minimum LED brightness; some users prefer a small amount of backlighting
// at all times, regardless of screen content.  Higher values are brighter,
// or set to 0 to disable this feature.
short minBrightness = 0;


// LED transition speed; it's sometimes distracting if LEDs instantaneously
// track screen contents (such as during bright flashing sequences), so this
// feature enables a gradual fade to each new LED state.  Higher numbers yield
// slower transitions (max of 255), or set to 0 to disable this feature
// (immediate transition of all LEDs).

short fade = 125;

int leds[][2] = {
    {3,5}, {2,5}, {1,5}, {0,5}, // Bottom edge, left half
    {0,4}, {0,3}, {0,2}, {0,1}, // Left edge
    {0,0}, {1,0}, {2,0}, {3,0}, {4,0}, // Top edge
    {5,0}, {6,0}, {7,0}, {8,0}, // More top edge
    {8,1}, {8,2}, {8,3}, {8,4}, // Right edge
    {8,5}, {7,5}, {6,5}, {5,5}  // Bottom edge, right half
    
};

int main(int argc, const char * argv[])
{
    
    @autoreleasepool {
        
        //  VARIABLES
        // --------------------------------------------------------------
        unsigned char   *grab = NULL;
        long            grabSize=0;
        int             ledColor[N_LEDS][3];
        int             prevColor[N_LEDS][3];
        int             gamma[256][3];
        int             temperature[256][3];
        long            pixelOffset[N_LEDS][256];
        int             i, j, o, rb, g, c, weight, deficit, overshot, sum, s2;
        float           f, range, step, start;
        int             x[16], y[16], row, col;
        int             fd, bytesToGo, bytesSent;
        unsigned char   buffer[6 + (N_LEDS * 3)];
        struct termios  tty;
        long            *offsets;
        
        
        //  SAFETY CHECKS
        // --------------------------------------------------------------
        
		if(argc < 2) {
		   (void)printf("Usage: %s device\n", argv[0]);
		   return 1;
		}

		if((fd = open(argv[1],O_RDWR | O_NOCTTY | O_NONBLOCK)) < 0) {
		   (void)printf("Can't open device '%s'.\n", argv[1]);
		   return 1;
		}
        
        
        // Serial port config swiped from RXTX library (rxtx.qbang.org):
        tcgetattr(fd, &tty);
        tty.c_iflag       = INPCK;
        tty.c_lflag       = 0;
        tty.c_oflag       = 0;
        tty.c_cflag       = CREAD | CS8 | CLOCAL;
        tty.c_cc[ VMIN ]  = 0;
        tty.c_cc[ VTIME ] = 0;
        cfsetispeed(&tty, B115200);
        cfsetospeed(&tty, B115200);
        tcsetattr(fd, TCSANOW, &tty);
        
        
        //  INITIALIZATION
        // --------------------------------------------------------------
        
        
        // Initialize our serial data
        bzero(buffer, sizeof(buffer));  // Clear LED buffer
        
        // Header only needs to be initialized once, not
        // inside rendering loop -- number of LEDs is constant:
        buffer[0] = 'A';                          // Magic word
        buffer[1] = 'd';
        buffer[2] = 'a';
        buffer[3] = (N_LEDS - 1) >> 8;            // LED count high byte
        buffer[4] = (N_LEDS - 1) & 0xff;          // LED count low byte
        buffer[5] = buffer[3] ^ buffer[4] ^ 0x55; // Checksum
        
        // Find the active display
        CGDirectDisplayID activeDisplay = kCGDirectMainDisplay;
        long width = CGDisplayPixelsWide(activeDisplay);
        long height = CGDisplayPixelsHigh(activeDisplay);
        
        
        // Compute the offset values for each LED
        for(i=0; i<N_LEDS; i++) {
            // Precompute columns, rows of each sampled point for this LED
            range = (float)width / N_LEDS_ACROSS;
            step  = range / 16.0;
            start = range * (float)leds[i][0] + step * 0.5;
            for(col=0; col<16; col++) x[col] = (int)(start + step * (float)col);
            
            range = (float)height / N_LEDS_DOWN;
            step  = range / 16.0;
            start = range * (float)leds[i][1] + step * 0.5;
            for(row=0; row<16; row++) y[row] = (int)(start + step * (float)row);
            
            // Get offset to each pixel within full screen capture
            for(row=0; row<16; row++) {
                for(col=0; col<16; col++) {
                    pixelOffset[i][row * 16 + col] = y[row] * width + x[col];
                }
            }
            
        }
        
        
        // Initialize gamma and temperature table
        for(i=0; i<256; i++) {
            f           = pow((float)i / 255.0, 2.8);
            gamma[i][0] = (int)(f * 255.0);
            gamma[i][1] = (int)(f * 240.0);
            gamma[i][2] = (int)(f * 220.0);
            temperature[i][0] = (int)(i*(kelvin_table[color_temperature][0]/255.0));
            temperature[i][1] = (int)(i*(kelvin_table[color_temperature][1]/255.0));
            temperature[i][2] = (int)(i*(kelvin_table[color_temperature][2]/255.0));
        }
        
        
        // Initialize previous color table
        for (i=0; i<N_LEDS; i++) {
            prevColor[i][0] = prevColor[i][1] = prevColor[i][2] = minBrightness/3;
        }
        
        // Initialize grab array
        grabSize = width * height * 4;
        grab = (unsigned char*)(calloc(grabSize, sizeof(unsigned char)));
        
        //  PER FRAME PROCESSING
        // --------------------------------------------------------------
        for(;;)
        {
            // Grab a screenshot
            CGImageRef imageRef = CGDisplayCreateImage(activeDisplay);
            CGDataProviderRef provider = CGImageGetDataProvider(imageRef);
            CFDataRef dataRef = CGDataProviderCopyData(provider);
            
            memcpy(grab, CFDataGetBytePtr(dataRef), grabSize);
            
            CFRelease(dataRef);
            CGImageRelease(imageRef);
            
            weight = 257 - fade;
            j = 6;
            
            for (i=0; i<N_LEDS; i++) {
                // special handling
                // switch off fist two and last two leds
                if(i==0 || i==1 || i==23 || i==24)
                {
                    ledColor[i][0] = ledColor[i][1] = ledColor[i][2] = 0;
                }
                else
                {
                    
                    offsets = pixelOffset[i];
                    rb = g = 0;
                    for(o=0; o<256; o++) {
                        c   = (*((int*)&grab[4*offsets[o]])&0xffffff00>>8); // RGB values in lower 3 bytes, also we are on a 64-bit machine
                        rb += c & 0x00ff00ff; // Bit trickery: R+B can accumulate in one var
                        g  += c & 0x0000ff00;
                    }
                    
                    // Blend new pixel value with the value from the prior frame
                    ledColor[i][0]  = (unsigned char)((((rb >> 24) & 0xff) * weight + prevColor[i][0] * fade) >> 8);
                    ledColor[i][1]  = (unsigned char)(((( g >> 16) & 0xff) * weight + prevColor[i][1] * fade) >> 8);
                    ledColor[i][2]  = (unsigned char)((((rb >>  8) & 0xff) * weight + prevColor[i][2] * fade) >> 8);
                    
                    // Boost pixels that fall below the minimum brightness
                    sum = ledColor[i][0] + ledColor[i][1] + ledColor[i][2];
                    if(sum < minBrightness) {
                        if(sum == 0) { // To avoid divide-by-zero
                            deficit = minBrightness / 3; // Spread equally to R,G,B
                            ledColor[i][0] = deficit;
                            ledColor[i][1] = deficit;
                            ledColor[i][2] = deficit;
                        } else {
                            deficit = minBrightness - sum;
                            s2      = sum * 2;
                            // Spread the "brightness deficit" back into R,G,B in proportion to
                            // their individual contribition to that deficit.  Rather than simply
                            // boosting all pixels at the low end, this allows deep (but saturated)
                            // colors to stay saturated...they don't "pink out."
                            ledColor[i][0] += deficit * (sum - ledColor[i][0]) / s2;
                            ledColor[i][1] += deficit * (sum - ledColor[i][1]) / s2;
                            ledColor[i][2] += deficit * (sum - ledColor[i][2]) / s2;
                        }
                    }else {
                        // special handling
                        // adjust for max brightness for lower leds
                        // cause the desk and monitor stand is to too reflective
                        // for my taste.
                        // almost the opposite of minimum brightness handling
                        if (sum > maxBrightness && (i==21 || i==22 || i==2 || i==3 )) {
                            overshot        = sum - maxBrightness;
                            s2              = sum * 2;
                            ledColor[i][0] -= overshot * (sum - ledColor[i][0]) / s2;
                            ledColor[i][1] -= overshot * (sum - ledColor[i][1]) / s2;
                            ledColor[i][2] -= overshot * (sum - ledColor[i][2]) / s2;
                            
                        }
                        if (ledColor[i][0] < 0 ) ledColor[i][0] = 0;
                        if (ledColor[i][1] < 0 ) ledColor[i][1] = 0;
                        if (ledColor[i][2] < 0 ) ledColor[i][2] = 0;
                    }
                }
                
                buffer[j++] = gamma[  temperature[  ledColor[i][0]  ][0]  ][0];
                buffer[j++] = gamma[  temperature[  ledColor[i][1]  ][1]  ][1];
                buffer[j++] = gamma[  temperature[  ledColor[i][2]  ][2]  ][2];
                
                
                prevColor[i][0] = ledColor[i][0];
                prevColor[i][1] = ledColor[i][1];
                prevColor[i][2] = ledColor[i][2];
                
            }
            
            
            // Issue color data to LEDs.  Each OS is fussy in different
            // ways about serial output.  This arrangement of drain-and-
            // write-loop seems to be the most relable across platforms:
            tcdrain(fd);
            for(bytesSent=0, bytesToGo=sizeof(buffer); bytesToGo > 0;) {
                if((i=(int)write(fd,&buffer[bytesSent],bytesToGo)) > 0) {
                    bytesToGo -= i;
                    bytesSent += i;
                }
            }
        }
        
        close(fd);
        
    }
    return 0;
}

