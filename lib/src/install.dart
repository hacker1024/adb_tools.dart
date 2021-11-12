import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:async/async.dart';
import 'package:dio/dio.dart';
import 'package:html/parser.dart';
import 'package:path/path.dart';
import 'package:yes/yes.dart';

/// Downloads the latest version of the SDK command-line tools.
///
/// The archive is saved in the given [location] directory, and a [File] object
/// representing it is returned.
/// [onReceiveProgress] is called periodically with the progress of the
/// download.
/// If [deleteOnError] is true, the archive is deleted if an error occurs when
/// downloading.
Future<File> downloadCmdlineToolsArchive(
  Directory location, {
  ProgressCallback? onReceiveProgress,
  bool deleteOnError = true,
}) async {
  final dio = Dio();
  final archiveUrl = await _getCmdlineToolsArchiveUrl(dio);
  final archiveFile = File(join(location.path, archiveUrl.pathSegments.last));
  await dio.downloadUri(
    archiveUrl,
    archiveFile.path,
    onReceiveProgress: onReceiveProgress,
    deleteOnError: deleteOnError,
  );
  return archiveFile;
}

/// Scrapes the SDK command line tools download page for the download link to
/// the latest version.
Future<Uri> _getCmdlineToolsArchiveUrl(final Dio dio) async {
  final String osId;
  if (Platform.isMacOS) {
    osId = 'mac';
  } else if (Platform.isLinux) {
    osId = 'linux';
  } else if (Platform.isWindows) {
    osId = 'win';
  } else {
    throw const CmdlineToolsInstallUnsupportedPlatformException();
  }

  final html = (await dio.get('https://developer.android.com/studio')).data;
  final document = parse(html);
  final downloadUrlString = document
      .getElementById('agree-button__sdk_${osId}_download')
      ?.attributes['href'];
  if (downloadUrlString == null) {
    throw FormatException(
      'Could not locate commandline tools archive URL!',
      document,
    );
  }

  return Uri.parse(downloadUrlString);
}

/// Installs the SDK command line tools from the given [archiveFile].
///
/// This function uses synchronous I/O, and is therefore intended to be called
/// in a secondary isolate in GUI applications.
/// The returned stream can be easily piped to a [SendPort].
///
/// [location] represents the root of the Android SDK installation.
/// [archiveFile] is a reference to the Android SDK Command-line Tools archive.
/// It can be obtained with [downloadCmdlineToolsArchive].
/// If [deleteArchiveFile] is true, the archive file will be deleted as soon as
/// it is no longer needed.
/// If [launchPathSettings] is true, the native system path settings will be
/// launched after installation. This may not be supported on all platforms.
/// If [verbose] is true, subprocesses will be executed with verbose flags.
/// The Android SDK Platform Tools (adb, fastboot, etc.) can be installed if
/// [installPlatformTools] is set to true.
/// If [inheritStdio] is true, tools executed during installation will inherit
/// the standard I/O streams of the current process. This is useful in CLI
/// applications. As a side effect, required licences will not be automatically
/// accepted.
/// Note: If the user does not accept the licenses (which is possible when they
/// have direct access to stdin through [inheritStdio], this function is not
/// able to detect their denial. This can cause problems later on, for things
/// like PATH manipulation. Using [inheritStdio] is therefore not recommended,
/// unless the user is prevented from denying the license in another way.
///
/// This function depends on some external tools:
/// - Java (if [installPlatformTools] is true)
/// - p7zip or unzip (macOS and Linux)
/// - PowerShell 5.0+ (Windows)
Stream<CmdlineToolsInstallProgress> installCmdlineTools(
  Directory location,
  File archiveFile, {
  bool deleteArchiveFile = true,
  bool launchPathSettings = true,
  bool verbose = false,
  bool installPlatformTools = false,
  bool inheritStdio = false,
}) async* {
  /// Starts a process, handling its input and output streams.
  Future<_CmdlineToolsInstallSubprocess> startSubProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    void Function(IOSink stdin)? attachInput,
  }) async {
    final mode =
        inheritStdio ? ProcessStartMode.inheritStdio : ProcessStartMode.normal;
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      mode: mode,
    );
    final StreamGroup<CmdlineToolsInstallProgressMessage>? outputStreamGroup;
    if (mode == ProcessStartMode.normal) {
      outputStreamGroup = StreamGroup()
        ..add(
          process.stdout.transform(utf8.decoder).map(
                (message) => CmdlineToolsInstallProgressMessage(message),
              ),
        )
        ..add(
          process.stderr.transform(utf8.decoder).map(
                (message) =>
                    CmdlineToolsInstallProgressMessage(message, isError: true),
              ),
        )
        ..close();
      attachInput?.call(process.stdin);
    } else {
      outputStreamGroup = null;
    }
    return _CmdlineToolsInstallSubprocess(process, outputStreamGroup?.stream);
  }

  // Extract the command-line tools.
  yield const CmdlineToolsInstallExtracting(usingNativeUnzip: true);
  final cmdlineToolsExtractDirectory =
      Directory(join(location.path, 'cmdline-tools'))..createSync();
  late final bool usedNativeUnzip;

  CmdlineToolsInstallExtracting mapExtractingMessage(
    CmdlineToolsInstallProgressMessage message,
  ) =>
      CmdlineToolsInstallExtracting(
        usingNativeUnzip: true,
        message: message,
      );

  if (Platform.isMacOS || Platform.isLinux) {
    try {
      final extractSubprocess = await startSubProcess(
        '7z',
        ['x', archiveFile.path],
        workingDirectory: cmdlineToolsExtractDirectory.path,
      );
      if (extractSubprocess.outputStream != null) {
        yield* extractSubprocess.outputStream!.map(mapExtractingMessage);
      }
      final exitCode = await extractSubprocess.process.exitCode;
      if (exitCode != 0) throw CmdlineToolsExtractFailedException(exitCode);
      usedNativeUnzip = true;
    } on ProcessException {
      try {
        final extractSubprocess = await startSubProcess(
          'unzip',
          [
            if (verbose) '-v',
            archiveFile.path,
          ],
          workingDirectory: cmdlineToolsExtractDirectory.path,
        );
        if (extractSubprocess.outputStream != null) {
          yield* extractSubprocess.outputStream!.map(mapExtractingMessage);
        }
        final exitCode = await extractSubprocess.process.exitCode;
        if (exitCode != 0) throw CmdlineToolsExtractFailedException(exitCode);
        usedNativeUnzip = true;
      } on ProcessException {
        usedNativeUnzip = false;
      }
    }
  } else if (Platform.isWindows) {
    try {
      final extractSubprocess = await startSubProcess(
        'powershell',
        [
          '-command',
          "Expand-Archive -Force -LiteralPath '${archiveFile.path}' -DestinationPath '${cmdlineToolsExtractDirectory.path}'",
        ],
      );
      if (extractSubprocess.outputStream != null) {
        yield* extractSubprocess.outputStream!.map(mapExtractingMessage);
      }
      final exitCode = await extractSubprocess.process.exitCode;
      if (exitCode != 0) throw CmdlineToolsExtractFailedException(exitCode);
      usedNativeUnzip = true;
    } on ProcessException {
      usedNativeUnzip = false;
    }
  } else {
    usedNativeUnzip = false;
  }
  if (!usedNativeUnzip) {
    // TODO improve Dart extracting performance
    yield const CmdlineToolsInstallExtracting(usingNativeUnzip: false);
    final archive = ZipDecoder()
        .decodeBuffer(InputFileStream.file(archiveFile, byteOrder: BIG_ENDIAN));
    for (final file in archive.files) {
      if (file.isFile) {
        final data = file.content as List<int>;
        File(join(location.path, file.name))
          ..createSync(recursive: true)
          ..writeAsBytesSync(data);
      } else {
        Directory(join(location.path, file.name)).createSync(recursive: true);
      }
    }
  }

  // Delete the archive.
  if (deleteArchiveFile) archiveFile.deleteSync();

  // Move the commandline tools into their proper location in the Android SDK.
  final Directory cmdlineToolsDirectory;
  try {
    cmdlineToolsDirectory =
        Directory(join(cmdlineToolsExtractDirectory.path, 'cmdline-tools'))
            .renameSync(join(cmdlineToolsExtractDirectory.path, 'latest'));
  } on FileSystemException catch (e) {
    throw CmdlineToolsPrepareFailedException(e);
  }

  // Install the SDK platform tools.
  if (installPlatformTools) {
    yield const CmdlineToolsInstallInstallingPlatformTools(null);
    YesController? yesController;
    final platformToolsInstallSubprocess = await startSubProcess(
      join(
        cmdlineToolsDirectory.path,
        'bin',
        Platform.isWindows ? 'sdkmanager.bat' : 'sdkmanager',
      ),
      [
        if (verbose) '--verbose',
        '--install',
        'platform-tools',
      ],
      attachInput: yes,
    );
    if (platformToolsInstallSubprocess.outputStream != null) {
      await for (final message
          in platformToolsInstallSubprocess.outputStream!) {
        yield CmdlineToolsInstallInstallingPlatformTools(message);
      }
    }
    final exitCode = await platformToolsInstallSubprocess.process.exitCode;
    await yesController?.done; // The yes operation completes when stdin closes.
    if (exitCode != 0) throw PlatformToolsInstallFailedException(exitCode);
  }

  if (launchPathSettings) {
    if (Platform.isWindows) {
      // https://serverfault.com/a/351154
      Process.start(
        'rundll32',
        const ['sysdm.cpl,EditEnvironmentVariables'],
        mode: ProcessStartMode.detached,
      );
    }
  }

  // Finish up.
  yield CmdlineToolsInstallCompleted(
    location,
    [
      const ['cmdline-tools', 'latest', 'bin'],
      if (installPlatformTools) const ['platform-tools'],
    ],
  );
}

/// A class representing a stage in the Android SDK command-line tools
/// installation process.
abstract class CmdlineToolsInstallProgress {
  final CmdlineToolsInstallProgressMessage? message;

  const CmdlineToolsInstallProgress([this.message]);
}

/// A class representing the extraction stage of the Android SDK command-line
/// tools installation process.
class CmdlineToolsInstallExtracting extends CmdlineToolsInstallProgress {
  final bool usingNativeUnzip;

  const CmdlineToolsInstallExtracting({
    required this.usingNativeUnzip,
    CmdlineToolsInstallProgressMessage? message,
  }) : super(message);
}

/// A class representing the platform tools installation stage of the Android
/// SDK command-line tools installation process.
class CmdlineToolsInstallInstallingPlatformTools
    extends CmdlineToolsInstallProgress {
  const CmdlineToolsInstallInstallingPlatformTools(
    CmdlineToolsInstallProgressMessage? message,
  ) : super(message);
}

/// A class representing the completion of the Android SDK command-line tools
/// installation process.
class CmdlineToolsInstallCompleted extends CmdlineToolsInstallProgress {
  final Directory location;
  final List<List<String>> relativePathEntries;

  const CmdlineToolsInstallCompleted(this.location, this.relativePathEntries);

  Iterable<Directory> get directPathEntries {
    final sdkPath = location.path;
    return relativePathEntries
        .map((relativePath) => Directory(joinAll([sdkPath, ...relativePath])));
  }
}

/// A message outputted during Android SDK command-line tools installation.
class CmdlineToolsInstallProgressMessage {
  final String text;
  final bool isError;

  const CmdlineToolsInstallProgressMessage(this.text, {this.isError = false});
}

class _CmdlineToolsInstallSubprocess {
  final Process process;
  final Stream<CmdlineToolsInstallProgressMessage>? outputStream;

  const _CmdlineToolsInstallSubprocess(
    this.process, [
    this.outputStream,
  ]);
}

/// An exception representing a failure during the Android SDK command-line
/// tools installation process.
class CmdlineToolsInstallFailedException implements Exception {
  const CmdlineToolsInstallFailedException();
}

/// An exception representing a failure during the Android SDK command-line
/// tools installation process, due to the platform being unsupported.
class CmdlineToolsInstallUnsupportedPlatformException
    extends CmdlineToolsInstallFailedException {
  const CmdlineToolsInstallUnsupportedPlatformException();
}

/// An exception representing a failure during the Android SDK command-line
/// tools installation process, due to a failure extracting the command-line
/// tools archive.
class CmdlineToolsExtractFailedException
    extends CmdlineToolsInstallFailedException {
  final int errorCode;

  const CmdlineToolsExtractFailedException(this.errorCode);
}

/// An exception representing a failure during the Android SDK command-line
/// tools installation process, due to a failure preparing the SDK files.
class CmdlineToolsPrepareFailedException
    extends CmdlineToolsInstallFailedException {
  final FileSystemException fileSystemException;

  const CmdlineToolsPrepareFailedException(this.fileSystemException);
}

/// An exception representing a failure during the Android SDK command-line
/// tools installation process, due to a failed platform tools installation.
class PlatformToolsInstallFailedException
    extends CmdlineToolsInstallFailedException {
  final int errorCode;

  const PlatformToolsInstallFailedException(this.errorCode);
}
