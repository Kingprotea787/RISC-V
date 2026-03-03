#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum {
  PC_MODE_ANY = 0,
  PC_MODE_EXACT = 1,
  PC_MODE_RANGE = 2
} pc_mode_t;

typedef struct {
  const char *log_file;
  uint32_t expected_a0;
  int has_a0;
  pc_mode_t pc_mode;
  uint32_t expected_pc;
  uint32_t pc_low;
  uint32_t pc_high;
  const char *fb_dump_file;
  int min_nonzero_pixels;
} options_t;

// Parse the final line:
//   FINAL pc=0xXXXXXXXX a0=0xXXXXXXXX cycles=N
static int parse_final(FILE *fp, uint32_t *pc_out, uint32_t *a0_out, int *cycles_out) {
  char line[512];
  unsigned int pc = 0;
  unsigned int a0 = 0;
  int cycles = 0;
  int found = 0;

  while (fgets(line, sizeof(line), fp) != NULL) {
    if (sscanf(line, "FINAL pc=0x%x a0=0x%x cycles=%d", &pc, &a0, &cycles) == 3) {
      *pc_out = (uint32_t)pc;
      *a0_out = (uint32_t)a0;
      *cycles_out = cycles;
      found = 1;
    } else if (sscanf(line, "FINAL pc=0x%x a0=0x%x", &pc, &a0) == 2) {
      *pc_out = (uint32_t)pc;
      *a0_out = (uint32_t)a0;
      found = 1;
    }
  }

  return found;
}

static int count_nonzero_pixels(const char *fb_dump_file, int *count_out) {
  FILE *fp = fopen(fb_dump_file, "r");
  char line[128];
  unsigned int idx = 0;
  unsigned int pixel = 0;
  uint32_t *fb = NULL;
  int seq = 0;
  int count = 0;
  int i = 0;

  if (fp == NULL) {
    return 0;
  }

  fb = (uint32_t *)calloc(256u * 256u, sizeof(uint32_t));
  if (fb == NULL) {
    fclose(fp);
    return 0;
  }

  while (fgets(line, sizeof(line), fp) != NULL) {
    // Format A: "<idx> <pixel>" (event dump)
    if (sscanf(line, "%x %x", &idx, &pixel) == 2) {
      if (idx < 256u * 256u) {
        fb[idx] = (uint32_t)pixel;
      }
    // Format B: "<pixel>" (full framebuffer dump)
    } else if (sscanf(line, "%x", &pixel) == 1) {
      if (seq < 256 * 256) {
        fb[seq++] = (uint32_t)pixel;
      }
    }
  }

  fclose(fp);
  for (i = 0; i < 256 * 256; i++) {
    if ((fb[i] & 0x00ffffffu) != 0u) {
      count++;
    }
  }
  free(fb);
  *count_out = count;
  return 1;
}

static void print_usage(const char *argv0) {
  fprintf(stderr,
          "Usage:\n"
          "  %s --log <log_file> --a0 <value> [--pc <value> | --pc-range <low> <high>]\n"
          "      [--fb-dump <path> --min-nonzero-pixels <N>]\n",
          argv0);
}

static int parse_options(int argc, char **argv, options_t *opt) {
  int i;

  memset(opt, 0, sizeof(*opt));
  opt->pc_mode = PC_MODE_ANY;
  opt->min_nonzero_pixels = -1;

  for (i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--log") == 0) {
      if (i + 1 >= argc) return 0;
      opt->log_file = argv[++i];
    } else if (strcmp(argv[i], "--a0") == 0) {
      if (i + 1 >= argc) return 0;
      opt->expected_a0 = (uint32_t)strtoul(argv[++i], NULL, 0);
      opt->has_a0 = 1;
    } else if (strcmp(argv[i], "--pc") == 0) {
      if (i + 1 >= argc) return 0;
      opt->expected_pc = (uint32_t)strtoul(argv[++i], NULL, 0);
      opt->pc_mode = PC_MODE_EXACT;
    } else if (strcmp(argv[i], "--pc-range") == 0) {
      if (i + 2 >= argc) return 0;
      opt->pc_low = (uint32_t)strtoul(argv[++i], NULL, 0);
      opt->pc_high = (uint32_t)strtoul(argv[++i], NULL, 0);
      opt->pc_mode = PC_MODE_RANGE;
    } else if (strcmp(argv[i], "--fb-dump") == 0) {
      if (i + 1 >= argc) return 0;
      opt->fb_dump_file = argv[++i];
    } else if (strcmp(argv[i], "--min-nonzero-pixels") == 0) {
      if (i + 1 >= argc) return 0;
      opt->min_nonzero_pixels = atoi(argv[++i]);
    } else {
      return 0;
    }
  }

  if (opt->log_file == NULL || !opt->has_a0) {
    return 0;
  }
  if ((opt->pc_mode == PC_MODE_RANGE) && (opt->pc_low > opt->pc_high)) {
    return 0;
  }
  if ((opt->min_nonzero_pixels >= 0) && (opt->fb_dump_file == NULL)) {
    return 0;
  }

  return 1;
}

int main(int argc, char **argv) {
  FILE *fp = NULL;
  uint32_t got_pc = 0;
  uint32_t got_a0 = 0;
  int got_cycles = -1;
  int nonzero_pixels = 0;
  options_t opt;

  if (!parse_options(argc, argv, &opt)) {
    print_usage(argv[0]);
    return 2;
  }

  fp = fopen(opt.log_file, "r");
  if (fp == NULL) {
    fprintf(stderr, "Failed to open log file: %s\n", opt.log_file);
    return 2;
  }

  if (!parse_final(fp, &got_pc, &got_a0, &got_cycles)) {
    fclose(fp);
    fprintf(stderr, "No FINAL line found in %s\n", opt.log_file);
    return 1;
  }
  fclose(fp);

  if (got_a0 != opt.expected_a0) {
    fprintf(stderr,
            "CHECK FAILED: a0 mismatch, got 0x%08x expected 0x%08x\n",
            got_a0, opt.expected_a0);
    return 1;
  }

  if (opt.pc_mode == PC_MODE_EXACT && got_pc != opt.expected_pc) {
    fprintf(stderr,
            "CHECK FAILED: pc mismatch, got 0x%08x expected 0x%08x\n",
            got_pc, opt.expected_pc);
    return 1;
  }

  if (opt.pc_mode == PC_MODE_RANGE && (got_pc < opt.pc_low || got_pc > opt.pc_high)) {
    fprintf(stderr,
            "CHECK FAILED: pc out of range, got 0x%08x expected [0x%08x, 0x%08x]\n",
            got_pc, opt.pc_low, opt.pc_high);
    return 1;
  }

  if (opt.min_nonzero_pixels >= 0) {
    if (!count_nonzero_pixels(opt.fb_dump_file, &nonzero_pixels)) {
      fprintf(stderr, "CHECK FAILED: cannot open framebuffer dump %s\n", opt.fb_dump_file);
      return 1;
    }
    if (nonzero_pixels < opt.min_nonzero_pixels) {
      fprintf(stderr,
              "CHECK FAILED: nonzero pixels %d < required %d\n",
              nonzero_pixels, opt.min_nonzero_pixels);
      return 1;
    }
  }

  if (got_cycles >= 0) {
    printf("CHECK PASS: pc=0x%08x a0=0x%08x cycles=%d", got_pc, got_a0, got_cycles);
  } else {
    printf("CHECK PASS: pc=0x%08x a0=0x%08x", got_pc, got_a0);
  }
  if (opt.min_nonzero_pixels >= 0) {
    printf(" nonzero_pixels=%d", nonzero_pixels);
  }
  printf("\n");

  return 0;
}
