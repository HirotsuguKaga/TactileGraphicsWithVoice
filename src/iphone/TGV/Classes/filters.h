/* filters.h     Image filters
 *
 * Image filters, implemented in straight C for speed.
 */
#include <stdint.h>
#if TARGET_MAC
#include <ApplicationServices/ApplicationServices.h>
#endif
#include <CoreGraphics/CGImage.h>

#define BPP 4                    /* Bytes per pixel for RGBA */
#define LUMINANCES (255 * 3 + 1) /* Number of different luminance values */

void lumi_of_rgba(uint16_t *out, uint8_t *in, int width, int height);
void lumi_histogram(int *out, uint16_t *in, int width, int height);
void lumi_dilate(uint16_t *out, uint16_t *in,
                    int width, int height, int radius);
void lumi_boxblur(uint16_t *out, uint16_t *in,
                    int width, int height, int radius);

#if TARGET_MAC
void lumi_writefile(char *filename, uint16_t *in, int width, int height);
#endif
