// Synchronous clipboard write via a temporary textarea + execCommand.
// Why: Flutter's Clipboard.setData hops through a platform channel before
// reaching navigator.clipboard.writeText. Firefox treats the eventual call as
// outside the user gesture and silently denies it; Chrome is more permissive.
// document.execCommand('copy') runs synchronously inside the click handler so
// the gesture is still considered active.
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

void webCopy(String text) {
  final textarea = html.TextAreaElement()
    ..value = text
    ..style.position = 'fixed'
    ..style.left = '-9999px'
    ..style.opacity = '0';
  html.document.body!.append(textarea);
  textarea.focus();
  textarea.select();
  html.document.execCommand('copy');
  textarea.remove();
}
