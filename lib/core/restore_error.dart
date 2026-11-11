/// A restore stopped while writing documents: the ones before [file] are already replaced, so the data is part old,
/// part restored (the original's message for this is 恢复过程中出错，建议重启应用). Any other error from a restore means
/// nothing was written.
class RestoreWriteException implements Exception {
  RestoreWriteException(this.file, this.cause);
  final String file;
  final Object cause;

  @override
  String toString() => 'RestoreWriteException: $file: $cause';
}
