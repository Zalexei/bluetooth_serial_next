import 'dart:convert';
import 'dart:typed_data';

/// "41 42 0D 0A".
String toHex(List<int> bytes) => bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');

/// Text with control characters made visible, like "OK\r\n" shown as
/// "OK⏎" would hide what the device really sent.
String toVisibleText(List<int> bytes) {
  final text = const Utf8Decoder(allowMalformed: true).convert(bytes);
  final out = StringBuffer();
  for (final rune in text.runes) {
    out.write(switch (rune) {
      0x0d => r'\r',
      0x0a => '\\n\n',
      0x09 => r'\t',
      < 0x20 || 0x7f => '\\x${rune.toRadixString(16).padLeft(2, '0')}',
      _ => String.fromCharCode(rune),
    });
  }
  return out.toString();
}

/// Parses "41 42 0d0a" or "0x41,0x42"; returns null if it is not hex.
Uint8List? parseHex(String input) {
  final digits = input
      .replaceAll(RegExp(r'0x', caseSensitive: false), '')
      .replaceAll(RegExp(r'[\s,:;-]'), '');
  if (digits.isEmpty ||
      digits.length.isOdd ||
      !RegExp(r'^[0-9a-fA-F]+$').hasMatch(digits)) {
    return null;
  }
  return Uint8List.fromList([
    for (var i = 0; i < digits.length; i += 2)
      int.parse(digits.substring(i, i + 2), radix: 16),
  ]);
}
