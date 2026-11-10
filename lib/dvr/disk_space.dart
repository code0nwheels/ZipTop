import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _GetDiskFreeSpaceExNative = Int32 Function(
  Pointer<Utf16> directory,
  Pointer<Uint64> freeToCaller,
  Pointer<Uint64> total,
  Pointer<Uint64> totalFree,
);
typedef _GetDiskFreeSpaceExDart = int Function(
  Pointer<Utf16> directory,
  Pointer<Uint64> freeToCaller,
  Pointer<Uint64> total,
  Pointer<Uint64> totalFree,
);

/// Bytes free for this user on the volume holding [directory] (local drive
/// or network share), or null when it cannot be determined.
int? freeDiskBytes(String directory) {
  if (!Platform.isWindows) return null;
  final path = directory.toNativeUtf16();
  final free = calloc<Uint64>();
  try {
    final getFree = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<_GetDiskFreeSpaceExNative, _GetDiskFreeSpaceExDart>(
      'GetDiskFreeSpaceExW',
    );
    return getFree(path, free, nullptr, nullptr) == 0 ? null : free.value;
  } catch (_) {
    return null;
  } finally {
    calloc.free(path);
    calloc.free(free);
  }
}
