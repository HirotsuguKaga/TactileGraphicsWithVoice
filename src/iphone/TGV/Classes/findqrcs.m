/* findqrcs.m     Find and classify QR codes in an image
 */
#import "runle.h"
#import "findqrcs.h"
#import "Blob.h"
#import "findblobs.h"

#define max(a, b) ((a) > (b) ? (a) : (b))
#define min(a, b) ((a) < (b) ? (a) : (b))

// Number of different luminance values we use.
//
#define LUMINANCES (1 + 255 * 3)

// Bytes per pixel
//
# define BPP 4

typedef struct {
    unsigned char *bitmap;
    int width, height;
    int thresh;        // Threshold between dark and light
    int thresh05;      // Threshold of very very dark (0.5% are darker)
} BITMAP_PARAMS;

static void blur2d(unsigned char *bitmap, int width, int height, int radius)
{
# define LCOMP(b, x) ((x) >= 0 ? b[x] : b[((x)+stride)%BPP])
# define RCOMP(b, x) ((x) < stride ? b[x] : b[stride-BPP+(x)%BPP])
# define LCOMPV(b, x) ((x) >= 0 ? b[x] : b[(totbytes+(x))%stride])
# define RCOMPV(b, x) ((x) < totbytes ? b[x] : b[totbytes-stride+(x)%stride])
    struct rgb { int b, g, r; } accum;
    int stride = width * BPP;
    int totbytes = width * height * BPP;
    unsigned char *end;
    unsigned char *base;
    int denom = radius * 2 + 1;
    int l, c, r, i;
    int scratchlen = (width > height ? width : height) * BPP;
    unsigned char *scratch = malloc(scratchlen);
    
    end = bitmap + height * stride;
    for(base = bitmap; base < end; base += stride) {
        accum.b = (radius + 1) * base[0];
        accum.g = (radius + 1) * base[1];
        accum.r = (radius + 1) * base[2];
        for(c = 0; c < radius * BPP; c += BPP) {
            accum.b += base[c + 0];
            accum.g += base[c + 1];
            accum.r += base[c + 2];
        }
        for(    l = -BPP * (radius + 1), c = 0, r = BPP * radius;
                c < stride;
                l += BPP, c += BPP, r += BPP) {
            accum.b -= LCOMP(base, l + 0);
            accum.g -= LCOMP(base, l + 1);
            accum.r -= LCOMP(base, l + 2);
            accum.b += RCOMP(base, r + 0);
            accum.g += RCOMP(base, r + 1);
            accum.r += RCOMP(base, r + 2);
            scratch[c + 0] = (accum.b + radius) / denom;
            scratch[c + 1] = (accum.g + radius) / denom;
            scratch[c + 2] = (accum.r + radius) / denom;
            scratch[c + 3] = base[c + 3];
        }
        memcpy(base, scratch, stride);
    }
    
    end = bitmap + stride;
    for(base = bitmap; base < end; base += BPP) {
        accum.b = (radius + 1) * base[0];
        accum.g = (radius + 1) * base[1];
        accum.r = (radius + 1) * base[2];
        for(c = 0; c < radius * stride; c += stride) {
            accum.b += base[c + 0];
            accum.g += base[c + 1];
            accum.r += base[c + 2];
        }
        for(    l = -stride * (radius + 1), i = 0, c = 0, r = stride * radius;
                c < totbytes;
                l += stride, i += BPP, c += stride, r += stride) {
            accum.b -= LCOMPV(base, l + 0);
            accum.g -= LCOMPV(base, l + 1);
            accum.r -= LCOMPV(base, l + 2);
            accum.b += RCOMPV(base, r + 0);
            accum.g += RCOMPV(base, r + 1);
            accum.r += RCOMPV(base, r + 2);
            scratch[i + 0] = (accum.b + radius) / denom;
            scratch[i + 1] = (accum.g + radius) / denom;
            scratch[i + 2] = (accum.r + radius) / denom;
            scratch[i + 3] = base[c + 3];
        }
        for(i = 0, c = 0; c < totbytes; i += BPP, c += stride)
            * (int32_t *) (base + c) = * (int32_t *) (scratch + i);
    }
    
    free(scratch);
}

static int luminance(unsigned char *pixel)
{
    /* Return the luminance of the given pixel, which I'm defining as
     * b + g + r.
     */
    return pixel[0] + pixel[1] + pixel[2];
    // Alternate luminance def based on human perception.
    //return (int)
    //(pixel[0] * (.0722 * 3.0) +
     //pixel[1] * (.7152 * 3.0) +
     //pixel[2] * (.2126 * 3.0));
}

#ifdef COULD_BE_USEFUL
static float saturation(unsigned char *pixel)
{
    /* Return the saturation (density of hue) of the given pixel.
     */
    int low = min(min(pixel[0], pixel[1]), pixel[2]);
    int high = max(max(pixel[0], pixel[1]), pixel[2]);
    return high == 0 ? 0.0 : ((float) (high - low) / high);
}

static BOOL grayish(unsigned char *pixel)
{
    /* Return true if the given pixel (R,G,B,x) is reasonably close to
     * gray. I.e., if the saturation is below a certain level.
     */
    return saturation(pixel) < 0.2;
}
#endif /* COULD_BE_USEFUL */

static int lowspot(int *histogram)
{
    /* Find a low spot in the histogram that separates the dark pixels
     * from the light ones.
     * 
     * The reference histogram for this application has a big peak at
     * the right for light pixels, at a luminance around 500. Then there
     * are one or two much lower peaks at the left for dark pixels, at
     * luminances in the 300s and 400s.
     *
     * Depending on lighting conditions and other factors (such as the
     * white point setting of the camera), real histograms can differ
     * from this reference. We accommodate the differences by scaling
     * things to the width of the histogram.
     *
     * Current procedure: smooth the data twice, with two different
     * radii. Then look in the histogram for the rightmost low spot
     * that's reasonably far to the left of the peak.  If there's no low
     * spot, return a fixed distance to the left of the peak.  At the
     * very end, add an adjustment that was determined empirically, i.e.,
     * by trying some examples.
     */
# define REFERENCE_WIDTH 450
# define RADIUS1 30
# define RADIUS2 10
# define LEEWAY 80       // Low spot must be at least this far below big peak
# define FLATDELTA 105   // Distance below peak when dark area is flat
# define ADJUSTMENT 20   // Final empirical adjustment (aka fudge)
# define ROUND(x, radius) (((x) + radius) / (2 * radius + 1))
    int left, right;
    double scale;

    int radius1, radius2, leeway, flatdelta, adjustment;

    int ct;
    int lumin;
    int smooth1[LUMINANCES];
    int smooth2[LUMINANCES];
    int topcount, toplumin;
    int lowlumin, descending;

    // Figure out width of histogram. We measure the width from the
    // rightmost initial zero count to the highest count (the big peak).
    //
    left = -1;
    toplumin = 0;
    right = 0;
    topcount = 0;
    for(lumin = 0; lumin < LUMINANCES; lumin++) {
        if(left < 0 && histogram[lumin] > 0)
            left = lumin - 1;
        if(histogram[lumin] > topcount) {
            topcount = histogram[lumin];
            toplumin = lumin;
        }
        if(lumin > 0 && histogram[lumin] == 0 && histogram[lumin - 1] > 0)
            right = lumin;
    }
    scale = (double) (toplumin - left) / REFERENCE_WIDTH;
# define SCALE(x) ((int) ((x) * scale + 0.5))

    // Scale reference values for this histogram.
    //
    radius1 = SCALE(RADIUS1);
    radius2 = SCALE(RADIUS2);
    leeway = SCALE(LEEWAY);
    flatdelta = SCALE(FLATDELTA);
    adjustment = SCALE(ADJUSTMENT);

    // First smoothing, radius1.
    ct = 0;
    for(lumin = 0; lumin < radius1 * 2 + 1; lumin++)
        ct += histogram[lumin];
    for(lumin = radius1 + 1; lumin < LUMINANCES - radius1; lumin++) {
        ct = ct - histogram[lumin - radius1 - 1] + histogram[lumin + radius1];
        smooth1[lumin] = ROUND(ct, radius1);
    }
    // Second smoothing, radius2.
    ct = 0;
    for(lumin = 0; lumin < radius2 * 2 + 1; lumin++)
        ct += histogram[lumin];
    for(lumin = radius2 + 1; lumin < LUMINANCES - radius2; lumin++) {
        ct = ct - histogram[lumin - radius2 - 1] + histogram[lumin + radius2];
        smooth2[lumin] = ROUND(ct, radius2);
    }
#ifdef WRITE_SMOOTH2
    printf("smooth2\n");
    for(int i = lowlim; i < highlim; i++)
        printf("%d %d\n", i, smooth2[i]);
#endif

    // Find the big peak in the smoothed data.
    //
    topcount = 0;
    toplumin = 0;
    for(lumin = left; lumin < right; lumin++)
        if(smooth2[lumin] > topcount) {
            topcount = smooth2[lumin];
            toplumin = lumin;
        }

    // Look for low spots, i.e., spots where smoothed data changes from
    // descending to ascending.
    //
    descending = 0;
    lowlumin = left - 1;
    for(lumin = left + 1; lumin < toplumin - leeway; lumin++) {
        if(descending) {
            if(smooth2[lumin] > smooth2[lumin - 1]) {
//printf("turnaround %d\n", lumin);
                lowlumin = lumin - 1;
                descending = 0;
            }
        } else {
            if(smooth2[lumin] < smooth2[lumin - 1])
                descending = 1;
        }
    }

    // If no low spot found, use default.
    //
    if(lowlumin <= left)
        lowlumin = toplumin - flatdelta;

    return lowlumin + adjustment;
}


static void thresholds(BITMAP_PARAMS *bpar,
                    unsigned char *bitmap, int width, int height)
{
    /* Calculate threshold luminances: (a) between foreground (dark) and
     * background (light); (b) between not totally dark and totally
     * dark.
     */
# define TOTALLY_DARK_F 0.005
    int histogram[LUMINANCES], ct, thresh;
    int bytes, breakpt05, i;
    
    memset(histogram, 0, LUMINANCES * sizeof(int));
    bytes = width * height * BPP;
    for(i = 0; i < bytes; i += BPP)
        histogram[luminance(bitmap + i)]++;
#ifdef WRITE_HISTOGRAM
    for(i = 0; i < LUMINANCES; i++)
        printf("%d\n", histogram[i]);
#endif
    ct = 0;
    bpar->thresh = lowspot(histogram);
    breakpt05 = width * height * TOTALLY_DARK_F;
    for(thresh = 0; thresh < LUMINANCES; thresh++) {
        ct += histogram[thresh];
        if(ct >= breakpt05) {
            bpar->thresh05 = thresh;
            break;
        }
    }
}


static int classify(void *ck, int x, int y)
{
    BITMAP_PARAMS *p = ck;
    return luminance(p->bitmap + (p->width * y + x) * BPP) <= p->thresh;
}


static int slopect(void *ck, int x, int y, int wd)
{
    // Count the number of significant downslopes of luminance. This is
    // an attempt to measure the amount of variegation in a blob. QR
    // codes are noticeably variegated even when out of focus.
    //
    BITMAP_PARAMS *p = ck;
    int minbytes = 3 * BPP;
    int mindepth = (p->thresh - p->thresh05) / 4;
    int bytes = wd * BPP;
    unsigned char *base = p->bitmap + (p->width * y + x) * BPP;
    int sct, start, i;

    sct = 0;
    i = BPP;
    while(i < bytes) {
        for(    ;
                i < bytes && luminance(base + i) >= luminance(base + i - BPP);
                i += BPP)
            ;
        if(i >= bytes)
            break;
        start = i;
        for(    ;
                i < bytes && luminance(base + i) <= luminance(base + i - BPP);
                i += BPP)
            ;
        if(     i - start >= minbytes &&
                luminance(base + start) - luminance(base + i - BPP) >= mindepth)
            sct++;
    }
    return sct;
}


static int qr_candidate(Blob *blob)
{
    /* Determine whether the blob is a potential QR code.
     */
# define VARIEGATION_THRESH 1.0             /* CRUDE FOR NOW */
# define QRSIZE(x) ((x) >= 30 && (x) < 240) /* CRUDE FOR NOW */
    if(blob == nil)
        return 0;
    int width = blob.maxx - blob.minx + 1;
    int height = blob.maxy - blob.miny + 1;
#ifdef DEVELOP
    printf("class %d w %d h %d runCount %d slope %f\n",
        blob.bclass, width, height, blob.runCount, 
        blob.slopeCount / (double) blob.runCount);
#endif /* DEVELOP */
    return
        blob.bclass == 1 && QRSIZE(width) && QRSIZE(height) &&
            // blob.runCount < height + height && /* TRY AFTER COALESCE */
            blob.slopeCount / (double) blob.runCount >= VARIEGATION_THRESH;
}


NSArray *findqrcs_x(RUN ***startsp, uint8_t *bitmap,
                        size_t width, size_t height)
{
    // (This internal function returns the calculated runs through
    // *startsp, which is useful during development.)
    //
# define BLUR_RADIUS 3
    BITMAP_PARAMS p;
    RUN **starts;
    NSMutableArray *mres = [[[NSMutableArray alloc] init] autorelease];

    blur2d(bitmap, width, height, BLUR_RADIUS);

    thresholds(&p, bitmap, width, height);
    
    p.bitmap = bitmap;
    p.width = width;
    p.height = height;

    starts = encode(classify, slopect, &p, width, height);
    if(starts == NULL) {
        *startsp = NULL;
        return [mres copy]; // Empty array
    }
    NSMutableDictionary *dict = findblobs(width, height, starts);

    for(NSNumber *key in dict) {
        Blob *b = [dict objectForKey: key];
        if(qr_candidate(b))
            [mres addObject: b];
    }

    *startsp = starts;
    return [mres copy];
}


NSArray *findqrcs(uint8_t *bitmap, size_t width, size_t height)
{
    RUN **starts;
    return findqrcs_x(&starts, bitmap, width, height);
}
