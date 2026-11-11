/// `scheme://user:pass@host` → `scheme://host` anywhere in [text]: log lines carry full URLs (also Node's `[net] GET …`
/// lines and Dio's error messages), and subscription URLs can hold an account.
String redactUrls(String text) => text.replaceAllMapped(RegExp(r'([A-Za-z][A-Za-z0-9+.-]*://)[^/\s@]+@'), (m) => m[1]!);
