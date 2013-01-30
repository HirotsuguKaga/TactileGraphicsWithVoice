// Blob.h     Connected component
//
#import <Foundation/Foundation.h>
#import "runle.h"

@interface Blob : NSObject
@property (nonatomic) RUN *root;       // Representative run of the blob
@property (nonatomic) int bclass;      // Class of blob: 0 = bg, 1 = fg
@property (nonatomic) int minx, maxx;  // Leftmost, rightmost pixels
@property (nonatomic) int miny, maxy;  // Topmost, bottommost pixels
@property (nonatomic) int slopeCount;  // Number of gradation changes
@property (nonatomic) int runCount;    // Number of runs
@end
