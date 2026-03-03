#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

// Convert framebuffer dump to binary PPM (P6), default 256x256.
//
// Supported input formats:
// 1) Full dump: one hex word per line (0x00RRGGBB)
// 2) Event dump: "<pixel_index> <pixel_value>" per line
int main(int argc, char **argv) {
  const int width = 256;
  const int height = 256;
  const int pixels = width * height;
  FILE *in = NULL;
  FILE *out = NULL;
  uint32_t *fb = NULL;
  char line[128];
  unsigned int idx = 0;
  unsigned int p = 0;
  int i = 0;
  int seq = 0;

  if (argc != 3) {
    fprintf(stderr, "Usage: %s <fb_dump.hex> <out.ppm>\n", argv[0]);
    return 2;
  }

  in = fopen(argv[1], "r");
  if (in == NULL) {
    fprintf(stderr, "Failed to open %s\n", argv[1]);
    return 2;
  }

  out = fopen(argv[2], "wb");
  if (out == NULL) {
    fclose(in);
    fprintf(stderr, "Failed to open %s\n", argv[2]);
    return 2;
  }

  fb = (uint32_t *)calloc((size_t)pixels, sizeof(uint32_t));
  if (fb == NULL) {
    fclose(in);
    fclose(out);
    fprintf(stderr, "Out of memory\n");
    return 2;
  }

  while (fgets(line, sizeof(line), in) != NULL) {
    if (sscanf(line, "%x %x", &idx, &p) == 2) {
      if (idx < (unsigned int)pixels) {
        fb[idx] = (uint32_t)p;
      }
    } else if (sscanf(line, "%x", &p) == 1) {
      if (seq < pixels) {
        fb[seq++] = (uint32_t)p;
      }
    }
  }

  fprintf(out, "P6\n%d %d\n255\n", width, height);

  for (i = 0; i < pixels; i++) {
    uint8_t rgb[3];
    p = fb[i];
    rgb[0] = (uint8_t)((p >> 16) & 0xffu);
    rgb[1] = (uint8_t)((p >> 8) & 0xffu);
    rgb[2] = (uint8_t)(p & 0xffu);
    fwrite(rgb, 1, 3, out);
  }

  free(fb);
  fclose(in);
  fclose(out);
  return 0;
}
