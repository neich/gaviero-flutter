/// App theme and the highlight-class palette. The server sends semantic
/// tree-sitter capture names, never colors (§3.1): the phone's theme is its
/// own. Unknown classes render as plain text — that is a feature.
library;

import 'package:flutter/material.dart';

ThemeData buildTheme() => ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4FC3F7),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    );

const codeBackground = Color(0xFF16181D);
const codeFontFamily = 'monospace';

const _highlightColors = <String, Color>{
  'keyword': Color(0xFFC792EA),
  'string': Color(0xFFC3E88D),
  'number': Color(0xFFF78C6C),
  'comment': Color(0xFF697098),
  'function': Color(0xFF82AAFF),
  'method': Color(0xFF82AAFF),
  'constructor': Color(0xFF82AAFF),
  'type': Color(0xFFFFCB6B),
  'constant': Color(0xFFF78C6C),
  'variable': Color(0xFFEEFFFF),
  'property': Color(0xFF80CBC4),
  'operator': Color(0xFF89DDFF),
  'punctuation': Color(0xFF89DDFF),
  'attribute': Color(0xFFFFCB6B),
  'tag': Color(0xFFF07178),
  'label': Color(0xFFC792EA),
  'module': Color(0xFFFFCB6B),
  'escape': Color(0xFF89DDFF),
  'embedded': Color(0xFFEEFFFF),
  'macro': Color(0xFFC792EA),
};

/// Maps a semantic capture name to a style. Dotted captures fall back to
/// their head segment (`function.method` → `function`); unknown names get
/// no styling.
TextStyle? highlightStyle(String? className) {
  if (className == null) return null;
  var color = _highlightColors[className];
  if (color == null) {
    final head = className.split('.').first;
    color = _highlightColors[head];
  }
  if (color == null) return null;
  final style = TextStyle(color: color);
  if (className == 'comment') {
    return style.copyWith(fontStyle: FontStyle.italic);
  }
  return style;
}
