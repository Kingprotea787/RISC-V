#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Convert "v3.0 hex words addressed" into plain word-wise hex
// (one 32-bit word per line), filling address gaps with 0.
//
// Input:
//   v3.0 hex words addressed
//   00000: 00000413 00052137 ...
//
// Output:
//   00000413
//   00052137
//   ...

static int is_hex_word_token(const char *s) {
  size_t i;
  size_t n = strlen(s);
  if (n == 0) return 0;
  for (i = 0; i < n; i++) {
    if (!isxdigit((unsigned char)s[i])) return 0;
  }
  return 1;
}

static void emit_zero_words(FILE *out, uint64_t n) {
  uint64_t i;
  for (i = 0; i < n; i++) {
    fputs("00000000\n", out);
  }
}

int main(int argc, char **argv) {
  FILE *in = NULL;
  FILE *out = NULL;
  char line[8192];
  uint64_t cursor_words = 0;

  if (argc != 3) {
    fprintf(stderr, "Usage: %s <in_logisim.hex> <out_words.hex>\n", argv[0]);
    return 2;
  }

  in = fopen(argv[1], "r");
  if (in == NULL) {
    fprintf(stderr, "Failed to open %s\n", argv[1]);
    return 2;
  }

  out = fopen(argv[2], "w");
  if (out == NULL) {
    fclose(in);
    fprintf(stderr, "Failed to open %s\n", argv[2]);
    return 2;
  }

  while (fgets(line, sizeof(line), in) != NULL) {
    char *p = line;
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p == '\0') continue;
    if (strncmp(p, "v3.0", 4) == 0) continue;

    {
      char *colon = strchr(p, ':');
      char *tok = NULL;
      uint32_t addr_words = 0;
      uint64_t target_words = 0;

      if (colon == NULL) continue;

      *colon = '\0';
      addr_words = (uint32_t)strtoul(p, NULL, 16);
      target_words = (uint64_t)addr_words;

      if (target_words > cursor_words) {
        emit_zero_words(out, target_words - cursor_words);
        cursor_words = target_words;
      }

      tok = strtok(colon + 1, " \t\r\n");
      while (tok != NULL) {
        if (is_hex_word_token(tok)) {
          uint32_t w = (uint32_t)strtoul(tok, NULL, 16);
          fprintf(out, "%08x\n", (unsigned int)w);
          cursor_words++;
        }
        tok = strtok(NULL, " \t\r\n");
      }
    }
  }

  fclose(in);
  fclose(out);
  return 0;
}
