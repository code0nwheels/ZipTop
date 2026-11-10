// Loads a libmpv outside the app and checks it is one ZipTop can give DASH
// streams to. CI runs this on the macOS build, where nobody can watch a
// channel play:
//
//   dart run tool/mpv_probe.dart build/macos/Build/Products/Release/ZipTop.app/Contents/Frameworks/Mpv.framework/Mpv
//
// Prints mpv's and FFmpeg's versions. Exits 1 if the library can't be
// loaded or initialized, or is older than mpv 0.42 (the same rule as
// mpvPlaysDash in lib/player/mpv_player.dart, which needs Flutter and so
// can't be imported here).
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateNative = Pointer<Void> Function();
typedef _InitializeNative = Int32 Function(Pointer<Void>);
typedef _InitializeDart = int Function(Pointer<Void>);
typedef _SetOptionNative = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SetOptionDart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _GetPropertyNative = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _ErrorStringNative = Pointer<Utf8> Function(Int32);
typedef _ErrorStringDart = Pointer<Utf8> Function(int);

bool playsDash(String? mpvVersion) {
  final match = RegExp(r'v?(\d+)\.(\d+)').firstMatch(mpvVersion ?? '');
  if (match == null) return false;
  final major = int.parse(match.group(1)!);
  final minor = int.parse(match.group(2)!);
  return major > 0 || minor >= 42;
}

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('Usage: dart run tool/mpv_probe.dart <path to libmpv>');
    exit(2);
  }
  final DynamicLibrary lib;
  try {
    lib = DynamicLibrary.open(args.single);
  } catch (e) {
    stderr.writeln("Couldn't load ${args.single}: $e");
    exit(1);
  }
  final create = lib.lookupFunction<_CreateNative, _CreateNative>('mpv_create');
  final initialize = lib.lookupFunction<_InitializeNative, _InitializeDart>('mpv_initialize');
  final setOption = lib.lookupFunction<_SetOptionNative, _SetOptionDart>('mpv_set_option_string');
  final getProperty =
      lib.lookupFunction<_GetPropertyNative, _GetPropertyNative>('mpv_get_property_string');
  final free = lib.lookupFunction<_FreeNative, _FreeDart>('mpv_free');
  final destroy = lib.lookupFunction<_FreeNative, _FreeDart>('mpv_terminate_destroy');
  final errorString = lib.lookupFunction<_ErrorStringNative, _ErrorStringDart>('mpv_error_string');

  final handle = create();
  if (handle == nullptr) {
    stderr.writeln('mpv_create failed');
    exit(1);
  }
  using((arena) {
    for (final (name, value) in [('vo', 'null'), ('ao', 'null'), ('idle', 'yes')]) {
      setOption(handle, name.toNativeUtf8(allocator: arena), value.toNativeUtf8(allocator: arena));
    }
  });
  final status = initialize(handle);
  if (status < 0) {
    stderr.writeln('mpv_initialize failed: ${errorString(status).toDartString()}');
    exit(1);
  }

  String? property(String name) => using((arena) {
        final value = getProperty(handle, name.toNativeUtf8(allocator: arena));
        if (value == nullptr) return null;
        final text = value.toDartString();
        free(value.cast());
        return text;
      });

  final mpvVersion = property('mpv-version');
  final ffmpegVersion = property('ffmpeg-version');
  destroy(handle);

  stdout.writeln('mpv-version: $mpvVersion');
  stdout.writeln('ffmpeg-version: $ffmpegVersion');
  if (!playsDash(mpvVersion)) {
    stderr.writeln('This libmpv is older than 0.42: ZipTop would refuse DASH channels.');
    exit(1);
  }
  stdout.writeln('OK: ZipTop will play DASH with this libmpv.');
}
