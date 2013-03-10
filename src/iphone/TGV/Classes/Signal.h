// Signal.h     Play a short sound with a controlled periodicity
//
// Created by Jeffrey Scofield on 3/8/13.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

#define SIGNAL_INF_PERIOD 9999.0  // Infinite period, i.e., no signal

@interface Signal : NSObject
@property (nonatomic, retain) NSURL *signalToIssue;
@property (nonatomic) CFTimeInterval period;
@end