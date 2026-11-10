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

typedef _StatvfsNative = Int32 Function(Pointer<Utf8> path, Pointer<Uint8> buf);
typedef _StatvfsDart = int Function(Pointer<Utf8> path, Pointer<Uint8> buf);

/// Bytes free for this user on the volume holding [directory] (local drive
/// or network share), or null when it cannot be determined.
int? freeDiskBytes(String directory) {
  if (Platform.isWindows) return _windowsFreeBytes(directory);
  if (Platform.isLinux) return _linuxFreeBytes(directory);
  return null;
}

int? _windowsFreeBytes(String directory) {
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

/// `struct statvfs` on x86_64 glibc is 112 bytes; allocate extra headroom.
const _statvfsSize = 256;
const _fFrsizeOffset = 8;
const _fBavailOffset = 32;

int? _linuxFreeBytes(String directory) {
  final path = directory.toNativeUtf8();
  final buf = calloc<Uint8>(_statvfsSize);
  try {
    final statvfs = DynamicLibrary.process().lookupFunction<_StatvfsNative, _StatvfsDart>('statvfs');
    if (statvfs(path, buf) != 0) return null;
    final frsize = Pointer<Uint64>.fromAddress(buf.address + _fFrsizeOffset).value;
    final bavail = Pointer<Uint64>.fromAddress(buf.address + _fBavailOffset).value;
    return bavail * frsize;
  } catch (_) {
    return null;
  } finally {
    calloc.free(path);
    calloc.free(buf);
  }
}
