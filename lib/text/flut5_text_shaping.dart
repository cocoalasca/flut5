/// Whether [text] has characters that only come out right when the font
/// shapes the whole string: scripts whose letters join or reorder (Arabic,
/// Hebrew, the Indic scripts, Thai and their neighbours), combining marks,
/// and emoji built from several code points.
///
/// The per-glyph text pipeline draws each character on its own, so strings
/// like these go through the whole-string one instead. Plain Latin, Greek,
/// Cyrillic and CJK text never does, and costs one comparison per character.
bool flut5TextNeedsShaping(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x0300) continue;
    if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < text.length) {
      final low = text.codeUnitAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        final codePoint = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
        if (_supplementaryNeedsShaping(codePoint)) return true;
        i++;
      }
      continue;
    }
    if (_basicPlaneNeedsShaping(unit)) return true;
  }
  return false;
}

bool _basicPlaneNeedsShaping(int unit) {
  if (unit <= 0x036F) return true; // combining diacritical marks
  if (unit < 0x0483) return false; // Greek, Cyrillic
  if (unit <= 0x0489) return true; // Cyrillic combining marks
  if (unit < 0x0590) return false; // Cyrillic, Armenian
  // Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan, Mandaic, the Indic
  // scripts, Thai, Lao, Tibetan, Myanmar, Georgian and Hangul Jamo.
  if (unit <= 0x11FF) return true;
  if (unit >= 0x135D && unit <= 0x135F) return true; // Ethiopic marks
  if (unit < 0x1700) return false;
  // Tagalog through Khmer, Mongolian, and the Southeast Asian blocks.
  if (unit <= 0x1CFF) return true;
  if (unit >= 0x1DC0 && unit <= 0x1DFF) return true; // more combining marks
  if (unit < 0x200C) return false;
  if (unit <= 0x200F) return true; // zero-width joiners, direction marks
  if (unit >= 0x202A && unit <= 0x202E) return true; // direction embeddings
  if (unit >= 0x2066 && unit <= 0x2069) return true; // direction isolates
  if (unit >= 0x20D0 && unit <= 0x20FF) return true; // marks for symbols
  if (unit >= 0x2CEF && unit <= 0x2CF1) return true; // Coptic marks
  if (unit == 0x2D7F) return true; // Tifinagh joiner
  if (unit >= 0x2DE0 && unit <= 0x2DFF) return true; // Cyrillic marks
  if (unit >= 0x302A && unit <= 0x302F) return true; // CJK tone marks
  if (unit == 0x3099 || unit == 0x309A) return true; // kana voicing marks
  if (unit < 0xA66F) return false;
  if (unit <= 0xA69F) {
    return unit <= 0xA672 ||
        (unit >= 0xA674 && unit <= 0xA67D) ||
        unit >= 0xA69E;
  }
  if (unit == 0xA6F0 || unit == 0xA6F1) return true; // Bamum marks
  if (unit >= 0xA800 && unit <= 0xAAFF) return true; // Indic extensions
  if (unit >= 0xABC0 && unit <= 0xABFF) return true; // Meetei Mayek
  if (unit >= 0xD7B0 && unit <= 0xD7FF) return true; // Hangul Jamo extended
  if (unit >= 0xFB1D && unit <= 0xFDFF) return true; // presentation forms
  if (unit >= 0xFE00 && unit <= 0xFE0F) return true; // variation selectors
  if (unit >= 0xFE20 && unit <= 0xFE2F) return true; // half marks
  if (unit >= 0xFE70 && unit <= 0xFEFF) return true; // Arabic forms
  return false;
}

bool _supplementaryNeedsShaping(int codePoint) {
  // Right-to-left and Brahmic scripts of the supplementary plane.
  if (codePoint >= 0x10800 && codePoint <= 0x11FFF) return true;
  if (codePoint >= 0x1E000 && codePoint <= 0x1EFFF) return true;
  // Flags are pairs of these, and skin tones modify the emoji before them.
  if (codePoint >= 0x1F1E6 && codePoint <= 0x1F1FF) return true;
  if (codePoint >= 0x1F3FB && codePoint <= 0x1F3FF) return true;
  // Emoji tag sequences and supplementary variation selectors.
  return codePoint >= 0xE0000 && codePoint <= 0xE0FFF;
}

/// Whether [text] contains any glyph that renders as a multi-color bitmap
/// emoji (`Emoji_Presentation=Yes` or SMP emoji blocks), so the fill pass
/// preserves its native palette rather than tinting it to a solid silhouette.
bool flut5HasColorEmoji(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x231A) continue;
    if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < text.length) {
      final low = text.codeUnitAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        final codePoint = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
        if (codePoint >= 0x1F000 && codePoint <= 0x1FAFF) return true;
        i++;
      }
      continue;
    }
    if (_isBmpColorEmoji(unit)) return true;
  }
  return false;
}

bool _isBmpColorEmoji(int u) {
  if (u <= 0x23FA) {
    return u == 0x231A ||
        u == 0x231B ||
        (u >= 0x23E9 && u <= 0x23F3) ||
        (u >= 0x23F8 && u <= 0x23FA);
  }
  if (u == 0x25FD || u == 0x25FE) return true;
  if (u >= 0x2614 && u <= 0x26FD) {
    return u <= 0x2615 ||
        (u >= 0x2648 && u <= 0x2653) ||
        u == 0x267F ||
        u == 0x2693 ||
        u == 0x26A1 ||
        u == 0x26AA ||
        u == 0x26AB ||
        u == 0x26BD ||
        u == 0x26BE ||
        u == 0x26C4 ||
        u == 0x26C5 ||
        u == 0x26CE ||
        u == 0x26D4 ||
        u == 0x26EA ||
        u == 0x26F2 ||
        u == 0x26F3 ||
        u == 0x26F5 ||
        u == 0x26FA ||
        u == 0x26FD;
  }
  if (u >= 0x2705 && u <= 0x27BF) {
    return u == 0x2705 ||
        u == 0x270A ||
        u == 0x270B ||
        u == 0x2728 ||
        u == 0x274C ||
        u == 0x274E ||
        (u >= 0x2753 && u <= 0x2755) ||
        u == 0x2757 ||
        (u >= 0x2795 && u <= 0x2797) ||
        u == 0x27B0 ||
        u == 0x27BF;
  }
  return u == 0x2B1B || u == 0x2B1C || u == 0x2B50 || u == 0x2B55;
}
